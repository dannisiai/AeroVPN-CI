import Cocoa
import FlutterMacOS
import NetworkExtension
import os.log
import Darwin
import SystemConfiguration
import Security

/**
 * AeroVPN macOS Native Tunnel Controller
 *
 * Engine modes, in priority order:
 *   1. NetworkExtension (NETunnelProviderManager) when a PacketTunnel extension target is bundled.
 *   2. Standalone official sing-box darwin core with elevated privileges.
 *
 * Notes vs. earlier revisions:
 *   - There is no macOS privileged helper daemon in this project (the Go daemon under
 *     core/daemon is Windows-only), so the previous 127.0.0.1:9527 daemon probe was removed.
 *   - Node secrets are kept in RAM. The non-elevated path pipes the config over stdin
 *     (`sing-box run -c stdin`) and never touches disk. The elevated path writes a
 *     0600 config in a 0700 app-private directory and runs sing-box as a one-shot
 *     launchd job, stopped by its stable label instead of a possibly reused PID.
 *   - The Kill Switch value is reported truthfully. macOS has no OS-level firewall
 *     ownership here; when the tunnel is up, leak prevention comes from the sing-box
 *     tun `strict_route` in the generated config (see SingboxConfigBuilder).
 */
@main
class AppDelegate: FlutterAppDelegate {
  private static let log = OSLog(subsystem: "com.aerovpn.client.macos", category: "AppDelegate")
  private static let privilegedJobLabel = "com.aerovpn.client.singbox"
  private let CHANNEL = "com.aerovpn.client/vpn"

  private var vpnManager: NETunnelProviderManager?
  private let systemProxyController = MacOSSystemProxyController()
  private var singboxProcess: Process?
  private var privilegedJobActive = false
  private var privilegedMonitorCheckPending = false
  private var currentConfigJson = ""
  private var currentConfigPath: String?

  private var currentIp = ""
  private var currentCountry = ""
  private var currentCity = ""
  private var currentClashSecret = ""
  private var currentClashPort = 9090
  private var connectedDate: Date?
  private var isTunnelRunning = false
  private var killSwitchEnabled = true
  private var privilegedMonitorTimer: Timer?

  private var uplinkBps: Int64 = 0
  private var downlinkBps: Int64 = 0
  private var totalUpBytes: Int64 = 0
  private var totalDownBytes: Int64 = 0
  // Previous cumulative totals for the /connections snapshot deltas. Nil until
  // the first snapshot arrives (the first poll only sets the baseline).
  private var lastUploadTotal: Int64?
  private var lastDownloadTotal: Int64?
  private var telemetryTimer: Timer?

  /// App-private directory for the elevated config hand-off: 0700, per-user.
  private var configDir: String {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
    return base.appendingPathComponent("AeroVPN").path
  }

  private var launchDaemonSourcePath: String { (configDir as NSString).appendingPathComponent("aerovpn_singbox.launchd.plist") }
  private var launchDaemonPath: String { "/Library/LaunchDaemons/\(Self.privilegedJobLabel).plist" }

  private func launchDaemonPlistEntryExists() -> Bool? {
    var fileInfo = stat()
    if lstat(launchDaemonPath, &fileInfo) == 0 { return true }
    if errno == ENOENT { return false }
    return nil
  }

  // MARK: - App lifecycle

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    ensureConfigDir()
    // Restore BEFORE cleanup: the telemetry secret of a still-running elevated
    // job is recovered from the config hand-off files that cleanupStaleConfigs
    // deletes. This order is load-bearing - cleanup first made every app
    // restart drop traffic stats to zero until the next reconnect.
    restorePrivilegedProcessIfRunning()
    if !isTunnelRunning && systemProxyController.hasRecoveryData {
      DispatchQueue.global(qos: .utility).async { [weak self] in
        do {
          try self?.systemProxyController.restoreIfOwned()
        } catch {
          os_log("Could not restore a stale system proxy: %{public}@", log: Self.log, type: .error, error.localizedDescription)
        }
      }
    }
    cleanupStaleConfigs()
    let controller = mainFlutterWindow?.contentViewController as? FlutterViewController
    if let messenger = controller?.engine.binaryMessenger {
      setupMethodChannel(messenger: messenger)
    }
    loadVpnPreferences()
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationWillTerminate(_ notification: Notification) {
    if systemProxyController.hasRecoveryData {
      do {
        try systemProxyController.restoreIfOwned()
      } catch {
        os_log("Quit-time system proxy restoration failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
      }
    }
    // Quit-time stop shows the admin prompt; a cancelled prompt must never block or
    // fail termination. The stale root job (if any) is cleaned up automatically at
    // the next connect: the elevated-start path boots it out before installing a
    // fresh job (see startStandaloneProcessAfterStop). No unprivileged bootout is
    // attempted here — it cannot work against the system domain.
    stopActiveTunnel { error in
      if let error = error {
        os_log("Quit-time stop of the elevated sing-box job was cancelled or failed: %{public}@; the stale root job is cleaned up automatically at the next connect", log: Self.log, type: .info, error.localizedDescription)
      }
    }
    super.applicationWillTerminate(notification)
  }

  private func setupMethodChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: CHANNEL, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { return }

      switch call.method {
      case "startTunnel":
        guard let args = call.arguments as? [String: Any],
              let configJson = args["config_json"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing config_json", details: nil))
          return
        }
        self.currentIp = args["assigned_ip"] as? String ?? ""
        self.currentCountry = args["country"] as? String ?? ""
        self.currentCity = args["city"] as? String ?? ""
        self.currentConfigJson = configJson
        self.currentClashSecret = args["clash_secret"] as? String ?? ""
        self.currentClashPort = self.parseClashPort(from: configJson)
        self.killSwitchEnabled = args["kill_switch"] as? Bool ?? true

        self.startTunnel(configJson: configJson) { error in
          if let error = error {
            result(FlutterError(code: "START_FAILED", message: error.localizedDescription, details: nil))
          } else {
            result(["status": "connected"])
          }
        }

      case "stopTunnel":
        self.stopActiveTunnel { error in
          if let error = error {
            result(FlutterError(code: "STOP_FAILED", message: error.localizedDescription, details: nil))
          } else {
            result(["status": "disconnected"])
          }
        }

      case "getStatus":
        result([
          "status": self.isTunnelRunning ? "connected" : "disconnected",
          "running": self.isTunnelRunning
        ])

      case "getStats":
        let uptime = self.connectedDate != nil ? Int(Date().timeIntervalSince(self.connectedDate!)) : 0
        result([
          "status": self.isTunnelRunning ? "connected" : "disconnected",
          "assigned_ip": self.currentIp,
          "country": self.currentCountry,
          "city": self.currentCity,
          "uptime_sec": uptime,
          "kill_switch": self.killSwitchEnabled,
          "downlink_bps": self.downlinkBps,
          "uplink_bps": self.uplinkBps,
          "total_down_bytes": self.totalDownBytes,
          "total_up_bytes": self.totalUpBytes
        ])

      case "setKillSwitch":
        let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? true
        self.killSwitchEnabled = enabled
        // macOS uses the sing-box tun `strict_route` in the generated config rather than an
        // OS firewall, so there is no separate system rule to toggle here. The value is
        // persisted for the next connect and reported as-is; a live tunnel keeps the
        // strict_route it was started with until the user reconnects.
        os_log("Kill Switch set to %{public}@ (macOS: enforced via sing-box strict_route, applies on next connect)", log: Self.log, type: .info, enabled ? "on" : "off")
        result(["kill_switch": enabled])

      case "removeVpnProfile":
        self.removeVpnProfile { error in
          if let error = error {
            result(FlutterError(code: "REMOVE_PROFILE_FAILED", message: error.localizedDescription, details: nil))
          } else {
            result(["removed": true])
          }
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Config hygiene (no plaintext secret left behind)

  private func ensureConfigDir() {
    try? FileManager.default.createDirectory(
      atPath: configDir,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDir)
  }

  /// Removes leftover runtime config hand-off files from a previous crash/kill.
  private func cleanupStaleConfigs() {
    let fm = FileManager.default
    var dirs = [configDir, NSTemporaryDirectory()]
    dirs.append(contentsOf: fm.urls(for: .itemReplacementDirectory, in: .userDomainMask).map { $0.path })
    for dir in dirs {
      guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
      for item in items where item.hasPrefix("aerovpn_mac_") || item.hasPrefix("aerovpn_cfg_") ||
        item == "aerovpn_singbox.launchd.plist" {
        try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(item))
      }
    }
  }

  private func cleanTempConfig() {
    if let path = currentConfigPath {
      try? FileManager.default.removeItem(atPath: path)
      currentConfigPath = nil
    }
  }

  // MARK: - VPN preferences

  private func loadVpnPreferences(completion: (() -> Void)? = nil) {
    NETunnelProviderManager.loadAllFromPreferences { [weak self] (managers, error) in
      guard let self = self else { return }
      if let existing = managers?.first {
        self.vpnManager = existing
      } else {
        let newManager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.aerovpn.aerovpnClient.PacketTunnel"
        proto.serverAddress = "AeroVPN Gateway"
        newManager.protocolConfiguration = proto
        newManager.localizedDescription = "AeroVPN"
        newManager.isEnabled = true
        self.vpnManager = newManager
      }
      completion?()
    }
  }

  /// Native half of the logout contract (`removeVpnProfile`): removes every VPN
  /// profile this app owns from NetworkExtension preferences. Per-profile failures
  /// are logged and swallowed (success is still reported); only a fatal
  /// preference-load failure surfaces. Without a bundled PacketTunnel extension
  /// there is normally nothing to remove, and that still reports success.
  private func removeVpnProfile(completion: @escaping (Error?) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { [weak self] (managers, error) in
      guard let self = self else { return }
      if let error = error {
        completion(error)
        return
      }
      let providerId = "com.aerovpn.aerovpnClient.PacketTunnel"
      let owned = (managers ?? []).filter { manager in
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerId
      }
      guard !owned.isEmpty else {
        self.vpnManager = nil
        completion(nil)
        return
      }
      let group = DispatchGroup()
      for manager in owned {
        group.enter()
        // Best effort per profile: stop a live session, clear the provider
        // configuration, then drop the profile from preferences entirely.
        manager.connection.stopVPNTunnel()
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration = nil
        manager.removeFromPreferences { removeError in
          if let removeError = removeError {
            os_log("Failed to remove AeroVPN VPN profile: %{public}@", log: Self.log, type: .error, removeError.localizedDescription)
          }
          group.leave()
        }
      }
      group.notify(queue: .main) {
        // Drop the cached manager so the next start rebuilds it from scratch.
        self.vpnManager = nil
        completion(nil)
      }
    }
  }

  // MARK: - Start

  /// True only when a PacketTunnel extension (.appex) is actually bundled. The
  /// stock macOS Runner ships without one (and without the NE entitlement), and
  /// attempting the NetworkExtension path anyway makes macOS throw up a spurious
  /// "app wants to add VPN configuration" dialog before the fallback runs.
  private func hasPacketTunnelExtension() -> Bool {
    guard let pluginsURL = Bundle.main.builtInPlugInsURL,
          let contents = try? FileManager.default.contentsOfDirectory(atPath: pluginsURL.path) else {
      return false
    }
    return contents.contains { $0.hasSuffix(".appex") }
  }

  private func startTunnel(configJson: String, completion: @escaping (Error?) -> Void) {
    // NetworkExtension if the extension target is bundled; otherwise the standalone core.
    // NOTE: the stock macOS Runner ships without a PacketTunnel extension target + NE
    // entitlement, so this path normally falls through to the standalone core.
    if hasPacketTunnelExtension(), let manager = vpnManager, manager.isEnabled {
      let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
      proto.providerBundleIdentifier = "com.aerovpn.aerovpnClient.PacketTunnel"
      proto.serverAddress = "AeroVPN Gateway"
      // The node credentials (config_json, clash_secret) are persisted in the
      // tunnel profile's provider configuration: the NetworkExtension reads them
      // whenever it is started without start options (the provider falls back to
      // the profile's provider configuration, see PacketTunnelProvider.startTunnel).
      // Upstream sing-box-for-apple makes the same trade-off —
      // ExtensionProvider.persistStartOptions writes the start options (including
      // the config content) to disk for the extension. Logging out drops the
      // profile and its credentials (removeVpnProfile).
      proto.providerConfiguration = ["config_json": configJson, "clash_secret": currentClashSecret]
      manager.protocolConfiguration = proto
      manager.localizedDescription = "AeroVPN"

      manager.saveToPreferences { [weak self] error in
        guard let self = self else { return }
        if error == nil {
          manager.loadFromPreferences { error in
            if error == nil {
              do {
                try manager.connection.startVPNTunnel(options: [
                  "config_json": configJson as NSObject,
                  "clash_secret": self.currentClashSecret as NSObject
                ])
                // startVPNTunnel returns before the tunnel is up and can be silently
                // refused; only report running once the session reflects the start.
                let status = manager.connection.status
                if status != .disconnected && status != .invalid {
                  self.isTunnelRunning = true
                  self.connectedDate = Date()
                  self.startTelemetryPoller()
                  completion(nil)
                  return
                }
                os_log("NetworkExtension start was not taken up (status %d), falling back to standalone core", log: Self.log, type: .info, Int32(status.rawValue))
              } catch {
                os_log("NetworkExtension launch failed, falling back to standalone core: %{public}@", log: Self.log, type: .info, error.localizedDescription)
              }
            }
            self.startStandaloneProcess(configJson: configJson, completion: completion)
          }
          return
        }
        self.startStandaloneProcess(configJson: configJson, completion: completion)
      }
    } else {
      startStandaloneProcess(configJson: configJson, completion: completion)
    }
  }

  // MARK: - Standalone sing-box core mode

  private func startStandaloneProcess(configJson: String, completion: @escaping (Error?) -> Void) {
    stopActiveTunnel { [weak self] error in
      guard let self = self else { return }
      if let error = error {
        completion(error)
        return
      }
      self.startStandaloneProcessAfterStop(configJson: configJson, completion: completion)
    }
  }

  private func startStandaloneProcessAfterStop(configJson: String, completion: @escaping (Error?) -> Void) {
    guard let bin = locateSingboxBinary() else {
      completion(NSError(domain: "AeroVPN", code: -1, userInfo: [NSLocalizedDescriptionKey: "sing-box binary not found on macOS"]))
      return
    }

    if isRootOrSuid(bin) {
      // No elevation needed: pipe the config over stdin, never touching disk.
      if let checkError = preflightCheckStdin(binary: bin) {
        completion(checkError)
        return
      }
      do {
        let process = try spawnRunWithStdin(binary: bin) { [weak self] exitedProcess in
          DispatchQueue.main.async {
            guard let self = self, self.singboxProcess === exitedProcess else { return }
            self.singboxProcess = nil
            self.isTunnelRunning = false
            self.connectedDate = nil
            self.stopTelemetryPoller()
            self.cleanTempConfig()
            self.uplinkBps = 0
            self.downlinkBps = 0
            os_log("macOS sing-box exited with status %d", log: Self.log, type: .error, exitedProcess.terminationStatus)
          }
        }
        self.singboxProcess = process
        self.isTunnelRunning = true
        self.connectedDate = Date()
        self.startTelemetryPoller()
        os_log("Started macOS sing-box (stdin config) PID: %d", log: Self.log, type: .info, process.processIdentifier)
        self.configureSystemProxy(configJson: configJson) { error in
          if let error = error {
            self.stopActiveTunnel { _ in completion(error) }
          } else {
            completion(nil)
          }
        }
      } catch {
        os_log("Failed to launch macOS sing-box: %{public}@", log: Self.log, type: .error, error.localizedDescription)
        completion(error)
      }
      return
    }

    // Elevation required to create the utun device. `do shell script` only takes a path,
    // so write a 0600 file inside the 0700 app-private dir and remove it on stop.
    ensureConfigDir()
    let configPath = (configDir as NSString).appendingPathComponent("aerovpn_mac_\(UUID().uuidString).json")
    do {
      try configJson.write(toFile: configPath, atomically: true, encoding: .utf8)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
      self.currentConfigPath = configPath
    } catch {
      completion(error)
      return
    }

    if let checkError = preflightCheckFile(binary: bin, path: configPath) {
      cleanTempConfig()
      completion(checkError)
      return
    }

    let plistPath: String
    do {
      plistPath = try writePrivilegedLaunchDaemonPlist(binary: bin, configPath: configPath)
    } catch {
      cleanTempConfig()
      completion(error)
      return
    }

    let escapedSource = shellQuote(plistPath)
    let escapedTarget = shellQuote(launchDaemonPath)
    let label = Self.privilegedJobLabel
    // Recovery for a quit-time stop cancelled in the admin prompt: while we hold
    // administrator privileges anyway, boot out any stale job left running and
    // remove its leftover on-disk plist before installing the fresh job.
    // RunAtLoad is false in the installed plist, so the job is started here with
    // an explicit kickstart — a plist that survives a force-kill stays inert at boot.
    let appleScriptCmd = "do shell script \"/bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true; /bin/rm -f \" & quoted form of \"\(escapedTarget)\" & \"; /usr/bin/install -o root -g wheel -m 644 \" & quoted form of \"\(escapedSource)\" & \" \" & quoted form of \"\(escapedTarget)\" & \" && /bin/launchctl bootstrap system \" & quoted form of \"\(escapedTarget)\" & \" && /bin/launchctl kickstart system/\(label)\" & \" && /bin/rm -f \" & quoted form of \"\(escapedTarget)\" with administrator privileges"

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }
      let osascript = Process()
      osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      osascript.arguments = ["-e", appleScriptCmd]

      do {
        try osascript.run()
        osascript.waitUntilExit()

        if osascript.terminationStatus == 0 {
          try? FileManager.default.removeItem(atPath: plistPath)
          guard let pid = self.waitForPrivilegedLaunchDaemon() else {
            let state = self.privilegedLaunchDaemonState()
            let err = NSError(domain: "AeroVPN", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "launchd did not start the elevated sing-box job"])
            DispatchQueue.main.async {
              self.privilegedJobActive = state.loaded ?? true
              if state.loaded == false {
                self.cleanTempConfig()
              }
              completion(err)
            }
            return
          }
          DispatchQueue.main.async {
            self.privilegedJobActive = true
            self.startPrivilegedProcessMonitor()
            self.isTunnelRunning = true
            self.connectedDate = Date()
            self.startTelemetryPoller()
            os_log("Started elevated macOS sing-box launchd job, PID: %d", log: Self.log, type: .info, pid)
            self.configureSystemProxy(configJson: configJson) { error in
              if let error = error {
                self.stopActiveTunnel { _ in completion(error) }
              } else {
                completion(nil)
              }
            }
          }
        } else {
          try? FileManager.default.removeItem(atPath: plistPath)
          let err = NSError(domain: "AeroVPN", code: Int(osascript.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "User cancelled or privilege elevation failed"])
          DispatchQueue.main.async {
            self.cleanTempConfig()
            completion(err)
          }
        }
      } catch {
        try? FileManager.default.removeItem(atPath: plistPath)
        DispatchQueue.main.async {
          self.cleanTempConfig()
          completion(error)
        }
      }
    }
  }

  private func configureSystemProxy(configJson: String, completion: @escaping (Error?) -> Void) {
    let port: Int? = {
      guard let data = configJson.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let inbounds = json["inbounds"] as? [[String: Any]] else { return nil }
      for inbound in inbounds where inbound["type"] as? String == "mixed" && inbound["tag"] as? String == "mixed-in" {
        let host = inbound["listen"] as? String
        let port = inbound["listen_port"] as? Int ?? 0
        if host == "127.0.0.1", port >= 1024, port <= 65535 { return port }
      }
      return nil
    }()

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }
      do {
        if let port {
          try self.systemProxyController.enable(port: port)
        } else {
          try self.systemProxyController.restoreIfOwned()
        }
        DispatchQueue.main.async { completion(nil) }
      } catch {
        DispatchQueue.main.async { completion(error) }
      }
    }
  }

  private func locateSingboxBinary() -> String? {
    let candidates = [
      Bundle.main.resourcePath?.appending("/sing-box"),
      Bundle.main.bundlePath.appending("/Contents/MacOS/sing-box"),
      "/usr/local/bin/sing-box",
      "/opt/homebrew/bin/sing-box"
    ]
    for path in candidates {
      if let p = path, FileManager.default.isExecutableFile(atPath: p) {
        return p
      }
    }
    return nil
  }

  private func isRootOrSuid(_ bin: String) -> Bool {
    if getuid() == 0 { return true }
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: bin),
          let posixPerms = attrs[.posixPermissions] as? NSNumber else {
      return false
    }
    return (posixPerms.uint16Value & 0o4000) != 0
  }

  /// `sing-box run -c stdin`; config is written to the child's stdin pipe only.
  private func spawnRunWithStdin(binary: String, terminationHandler: @escaping (Process) -> Void) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["run", "-c", "stdin"]
    process.terminationHandler = terminationHandler
    let inputPipe = Pipe()
    process.standardInput = inputPipe
    try process.run()
    inputPipe.fileHandleForWriting.write(Data(currentConfigJson.utf8))
    try? inputPipe.fileHandleForWriting.close()
    return process
  }

  private func preflightCheckStdin(binary: String) -> Error? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["check", "-c", "stdin"]
    let inputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardError = errorPipe
    do {
      try process.run()
    } catch {
      return error
    }
    inputPipe.fileHandleForWriting.write(Data(currentConfigJson.utf8))
    try? inputPipe.fileHandleForWriting.close()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      return NSError(domain: "AeroVPN", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "sing-box config check failed: \(message)"])
    }
    return nil
  }

  private func preflightCheckFile(binary: String, path: String) -> Error? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["check", "-c", path]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    do {
      try process.run()
    } catch {
      return error
    }
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      return NSError(domain: "AeroVPN", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "sing-box config check failed: \(message)"])
    }
    return nil
  }

  private func shellQuote(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
  }

  private func writePrivilegedLaunchDaemonPlist(binary: String, configPath: String) throws -> String {
    ensureConfigDir()
    let job: [String: Any] = [
      "Label": Self.privilegedJobLabel,
      "ProgramArguments": [binary, "run", "-c", configPath],
      // RunAtLoad=false: if the app is force-killed between `install` and the
      // trailing `rm -f` of the bootstrap command, a leftover plist must not
      // make launchd run a stale-config sing-box as root on every boot. The job
      // is started explicitly with `launchctl kickstart` right after bootstrap.
      "RunAtLoad": false,
      "KeepAlive": false,
      "StandardOutPath": "/dev/null",
      "StandardErrorPath": "/dev/null"
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    try data.write(to: URL(fileURLWithPath: launchDaemonSourcePath), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: launchDaemonSourcePath)
    return launchDaemonSourcePath
  }

  private func privilegedLaunchDaemonState() -> (loaded: Bool?, pid: pid_t?) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    let serviceTarget = "system/\(Self.privilegedJobLabel)"
    process.arguments = ["print", serviceTarget]
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    do {
      try process.run()
    } catch {
      return (nil, nil)
    }
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      // launchctl has no machine-readable status API here. Only classify its
      // explicit missing-service diagnostic as unloaded; unknown errors stay unknown.
      let diagnostic = String(data: outputData, encoding: .utf8) ?? ""
      if diagnostic.contains("Could not find service") &&
          diagnostic.contains(Self.privilegedJobLabel) &&
          diagnostic.contains("domain for system") {
        return (false, nil)
      }
      return (nil, nil)
    }
    guard let output = String(data: outputData, encoding: .utf8),
          let firstLine = output.split(whereSeparator: \.isNewline).first,
          firstLine.trimmingCharacters(in: .whitespaces) == "\(serviceTarget) = {" else {
      return (nil, nil)
    }
    // `launchctl print` targets the system bootstrap domain explicitly. Its output
    // is human-readable rather than a stable machine interface, so an unrecognized
    // shape is treated as unknown instead of being confused with another job.
    guard let pidExpression = try? NSRegularExpression(pattern: "(?im)^\\s*pid\\s*=\\s*(\\d+)\\s*;?\\s*$") else {
      return (true, nil)
    }
    let outputRange = NSRange(output.startIndex..<output.endIndex, in: output)
    guard let match = pidExpression.firstMatch(in: output, range: outputRange),
          let pidRange = Range(match.range(at: 1), in: output),
          let pid = Int32(output[pidRange]) else {
      return (true, nil)
    }
    return (true, pid > 0 ? pid : nil)
  }

  private func waitForPrivilegedLaunchDaemon() -> pid_t? {
    for _ in 0..<25 {
      if let pid = privilegedLaunchDaemonState().pid {
        return pid
      }
      Thread.sleep(forTimeInterval: 0.2)
    }
    return nil
  }

  // MARK: - Stop

  private func stopActiveTunnel(completion: ((Error?) -> Void)? = nil) {
    if systemProxyController.hasRecoveryData {
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self = self else { return }
        do {
          try self.systemProxyController.restoreIfOwned()
          DispatchQueue.main.async { self.stopActiveTunnel(completion: completion) }
        } catch {
          DispatchQueue.main.async { completion?(error) }
        }
      }
      return
    }
    if let process = singboxProcess, process.isRunning {
      // Keep ownership and the visible running state until this child exits.
      // terminate() only sends a signal; it is not a stop acknowledgement.
      process.terminate()
      DispatchQueue.global(qos: .utility).async {
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
          Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
          // This is our still-owned Process, never a restored/detached PID.
          _ = Darwin.kill(process.processIdentifier, SIGKILL)
          let killDeadline = Date().addingTimeInterval(2)
          while process.isRunning && Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.1)
          }
        }
        DispatchQueue.main.async {
          if process.isRunning {
            completion?(NSError(domain: "AeroVPN", code: -14,
                                userInfo: [NSLocalizedDescriptionKey: "Timed out stopping the owned sing-box process"]))
          } else {
            if self.singboxProcess === process { self.singboxProcess = nil }
            self.stopActiveTunnel(completion: completion)
          }
        }
      }
      return
    }
    if let manager = vpnManager, hasPacketTunnelExtension(),
       manager.connection.status != .invalid, manager.connection.status != .disconnected {
      manager.connection.stopVPNTunnel()
      waitForNetworkExtensionStop(manager, attempts: 40) { error in
        if let error = error { completion?(error) }
        else { self.stopActiveTunnel(completion: completion) }
      }
      return
    }
    isTunnelRunning = false
    connectedDate = nil
    stopTelemetryPoller()
    privilegedMonitorTimer?.invalidate()
    privilegedMonitorTimer = nil

    vpnManager?.connection.stopVPNTunnel()

    singboxProcess = nil

    guard privilegedJobActive else {
      cleanTempConfig()
      uplinkBps = 0
      downlinkBps = 0
      completion?(nil)
      return
    }

    stopPrivilegedLaunchDaemon { error in
      if let error = error {
        let state = self.privilegedLaunchDaemonState()
        if state.loaded == false {
          if self.launchDaemonPlistEntryExists() == false {
            self.privilegedJobActive = false
            self.isTunnelRunning = false
            self.connectedDate = nil
            self.cleanTempConfig()
            self.uplinkBps = 0
            self.downlinkBps = 0
            completion?(nil)
          } else {
            // Keep the config and retryable state while the root launchd plist
            // remains on disk; it may be loaded again after a system restart.
            self.privilegedJobActive = true
            self.isTunnelRunning = false
            self.connectedDate = nil
            completion?(error)
          }
          return
        }
        self.privilegedJobActive = state.loaded ?? true
        self.isTunnelRunning = state.pid != nil
        self.connectedDate = self.isTunnelRunning ? Date() : nil
        if self.isTunnelRunning {
          self.startPrivilegedProcessMonitor()
          self.startTelemetryPoller()
        }
        completion?(error)
        return
      }
      self.privilegedJobActive = false
      self.isTunnelRunning = false
      self.connectedDate = nil
      self.cleanTempConfig()
      self.uplinkBps = 0
      self.downlinkBps = 0
      completion?(nil)
    }
  }

  private func waitForNetworkExtensionStop(_ manager: NETunnelProviderManager,
                                           attempts: Int,
                                           completion: @escaping (Error?) -> Void) {
    let status = manager.connection.status
    if status == .disconnected || status == .invalid { completion(nil); return }
    if attempts == 0 {
      completion(NSError(domain: "AeroVPN", code: -15,
                         userInfo: [NSLocalizedDescriptionKey: "Timed out stopping NetworkExtension"]))
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      self.waitForNetworkExtensionStop(manager, attempts: attempts - 1, completion: completion)
    }
  }

  private func stopPrivilegedLaunchDaemon(completion: @escaping (Error?) -> Void) {
    let escapedTarget = shellQuote(launchDaemonPath)
    // bootout is best-effort: it fails when nothing is loaded, so fail only if
    // the job is still present after it — otherwise an idle stop would surface
    // a spurious error.
    let appleScriptCmd = "do shell script \"/bin/launchctl bootout system/\(Self.privilegedJobLabel) >/dev/null 2>&1; if /bin/launchctl print system/\(Self.privilegedJobLabel) >/dev/null 2>&1; then exit 1; fi; /bin/rm -f \" & quoted form of \"\(escapedTarget)\" & \"; remove_status=$?; if [ $remove_status -ne 0 ]; then exit $remove_status; fi\" with administrator privileges"
    DispatchQueue.global(qos: .utility).async {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      process.arguments = ["-e", appleScriptCmd]
      do {
        try process.run()
        process.waitUntilExit()
      } catch {
        DispatchQueue.main.async { completion(error) }
        return
      }
      DispatchQueue.main.async {
        if process.terminationStatus == 0 {
          completion(nil)
        } else {
          completion(NSError(domain: "AeroVPN", code: Int(process.terminationStatus),
                             userInfo: [NSLocalizedDescriptionKey: "Could not stop the elevated sing-box launchd job"]))
        }
      }
    }
  }

  /// Observe launchd's reported job state; never signal a detached PID directly.
  private func startPrivilegedProcessMonitor() {
    privilegedMonitorTimer?.invalidate()
    privilegedMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      guard let self = self, self.privilegedJobActive, !self.privilegedMonitorCheckPending else { return }
      self.privilegedMonitorCheckPending = true
      DispatchQueue.global(qos: .utility).async {
        let state = self.privilegedLaunchDaemonState()
        DispatchQueue.main.async {
          self.privilegedMonitorCheckPending = false
          guard self.privilegedJobActive else { return }
          if state.loaded != nil && state.pid == nil && self.isTunnelRunning {
            self.isTunnelRunning = false
            self.connectedDate = nil
            self.stopTelemetryPoller()
            self.cleanTempConfig()
            self.uplinkBps = 0
            self.downlinkBps = 0
            os_log("Elevated macOS sing-box launchd job is loaded without a running process", log: Self.log, type: .error)
          } else if state.pid != nil {
            self.isTunnelRunning = true
          }
          if state.loaded == false {
            self.privilegedJobActive = false
            self.privilegedMonitorTimer?.invalidate()
            self.privilegedMonitorTimer = nil
          }
        }
      }
    }
  }

  private func restorePrivilegedProcessIfRunning() {
    let state = privilegedLaunchDaemonState()
    privilegedJobActive = state.loaded ?? true
    isTunnelRunning = state.pid != nil
    guard isTunnelRunning else { return }
    connectedDate = Date()
    // The per-session clash_api secret and port from before the restart are needed for
    // telemetry auth. Recover them from the still-present config hand-off file;
    // when they cannot be recovered, telemetry polling stays disabled (explicit
    // unauthorized state) instead of hammering loopback with 401s.
    if let (secret, port) = readClashConfigFromRunningConfig() {
      currentClashSecret = secret
      currentClashPort = port
    } else {
      currentClashSecret = ""
      currentClashPort = 9090
      os_log("Restored privileged sing-box job is running, but its telemetry secret could not be recovered; traffic stats stay at zero until the next reconnect", log: Self.log, type: .info)
    }
    startPrivilegedProcessMonitor()
    startTelemetryPoller()
  }

  /// Recovers the clash_api secret and port from the elevated job's config hand-off file
  /// (0600 JSON inside the 0700 app-private directory) after an app restart.
  private func readClashConfigFromRunningConfig() -> (String, Int)? {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(atPath: configDir) else { return nil }
    for item in items where item.hasPrefix("aerovpn_mac_") && item.hasSuffix(".json") {
      let path = (configDir as NSString).appendingPathComponent(item)
      guard let data = fm.contents(atPath: path),
            let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let experimental = config["experimental"] as? [String: Any],
            let clashApi = experimental["clash_api"] as? [String: Any],
            let secret = clashApi["secret"] as? String,
            !secret.isEmpty else {
        continue
      }
      let port = (clashApi["external_controller"] as? String)
        .flatMap { $0.split(separator: ":").last }
        .flatMap { Int($0) } ?? 9090
      return (secret, port)
    }
    return nil
  }

  private func parseClashPort(from configJson: String) -> Int {
    guard let data = configJson.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let exp = json["experimental"] as? [String: Any],
          let clash = exp["clash_api"] as? [String: Any],
          let ec = clash["external_controller"] as? String,
          let portStr = ec.split(separator: ":").last,
          let p = Int(portStr), p >= 1024, p <= 65535 else {
      return 9090
    }
    return p
  }

  // MARK: - Telemetry (local clash_api with per-session secret)

  private func startTelemetryPoller() {
    stopTelemetryPoller()
    // Fresh core session: discard any stale baseline so the first snapshot
    // after (re)connect only re-anchors the delta instead of reporting a spike.
    lastUploadTotal = nil
    lastDownloadTotal = nil
    telemetryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.fetchClashApiTraffic()
    }
  }

  private func stopTelemetryPoller() {
    telemetryTimer?.invalidate()
    telemetryTimer = nil
  }

  private func fetchClashApiTraffic() {
    // Upstream clash_api /traffic is a streaming endpoint (one flushed JSON
    // line per second, response never completes), which a completion-based
    // dataTask can never parse - the completion only fires on timeout/error,
    // so stats stayed at zero while connected. /connections is a plain GET
    // snapshot carrying the same counters cumulatively
    // (upstream v1.14.3 experimental/clashapi/connections.go:
    // downloadTotal/uploadTotal), so the per-second bitrate is the delta.
    guard let url = URL(string: "http://127.0.0.1:\(currentClashPort)/connections") else { return }
    // Explicit unauthorized state: without the session secret the core rejects
    // every poll (upstream clash_api auth), so stay quiet instead of looping 401s.
    if currentClashSecret.isEmpty {
      return
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 1.0
    request.setValue("Bearer \(currentClashSecret)", forHTTPHeaderField: "Authorization")

    URLSession.shared.dataTask(with: request) { [weak self] (data, _, _) in
      guard let self = self, let data = data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
      let upTotal = (json["uploadTotal"] as? NSNumber)?.int64Value ?? 0
      let downTotal = (json["downloadTotal"] as? NSNumber)?.int64Value ?? 0
      DispatchQueue.main.async {
        if let lastUp = self.lastUploadTotal, let lastDown = self.lastDownloadTotal {
          // A core restart resets the counters; never report a negative rate.
          if upTotal >= lastUp && downTotal >= lastDown {
            self.uplinkBps = upTotal - lastUp
            self.downlinkBps = downTotal - lastDown
          } else {
            self.uplinkBps = 0
            self.downlinkBps = 0
          }
        }
        self.lastUploadTotal = upTotal
        self.lastDownloadTotal = downTotal
        self.totalUpBytes = upTotal
        self.totalDownBytes = downTotal
      }
    }.resume()
  }
}

/// Applies the system-wide HTTP/HTTPS proxy to the current macOS network set
/// and restores the exact previous values when the tunnel stops. The saved
/// snapshot is kept in user defaults so a later app launch can recover from a
/// crash without overwriting proxy changes made by another application.
private final class MacOSSystemProxyController {
  private let recoveryKey = "aerovpn.systemProxyRecovery.v1"
  private let managedKeys = [
    kSCPropNetProxiesHTTPEnable as String,
    kSCPropNetProxiesHTTPProxy as String,
    kSCPropNetProxiesHTTPPort as String,
    kSCPropNetProxiesHTTPSEnable as String,
    kSCPropNetProxiesHTTPSProxy as String,
    kSCPropNetProxiesHTTPSPort as String,
    kSCPropNetProxiesProxyAutoConfigEnable as String,
    kSCPropNetProxiesProxyAutoDiscoveryEnable as String,
    kSCPropNetProxiesExceptionsList as String,
    kSCPropNetProxiesExcludeSimpleHostnames as String,
  ]

  var hasRecoveryData: Bool {
    UserDefaults.standard.dictionary(forKey: recoveryKey) != nil
  }

  func enable(port: Int) throws {
    guard port >= 1024, port <= 65535 else {
      throw NSError(domain: "AeroVPN.SystemProxy", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid system proxy port"])
    }
    try restoreIfOwned()

    try withPreferences { preferences in
      guard let currentSet = SCNetworkSetCopyCurrent(preferences),
            let services = SCNetworkSetCopyServices(currentSet) as? [SCNetworkService] else {
        throw Self.configurationError("Could not read macOS network services")
      }

      var changes: [(SCNetworkProtocol, [String: Any])] = []
      var serviceRecords: [String: [String: Any]] = [:]
      for service in services {
        guard let serviceID = SCNetworkServiceGetServiceID(service) as String? else { continue }
        let hadProxyProtocol = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) != nil
        if !hadProxyProtocol && !SCNetworkServiceAddProtocolType(service, kSCNetworkProtocolTypeProxies) {
          continue
        }
        guard let proxyProtocol = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
        let original = SCNetworkProtocolGetConfiguration(proxyProtocol) as? [String: Any] ?? [:]
        var applied = original
        applied[kSCPropNetProxiesHTTPEnable as String] = NSNumber(value: 1)
        applied[kSCPropNetProxiesHTTPProxy as String] = "127.0.0.1"
        applied[kSCPropNetProxiesHTTPPort as String] = NSNumber(value: port)
        applied[kSCPropNetProxiesHTTPSEnable as String] = NSNumber(value: 1)
        applied[kSCPropNetProxiesHTTPSProxy as String] = "127.0.0.1"
        applied[kSCPropNetProxiesHTTPSPort as String] = NSNumber(value: port)
        applied[kSCPropNetProxiesProxyAutoConfigEnable as String] = NSNumber(value: 0)
        applied[kSCPropNetProxiesProxyAutoDiscoveryEnable as String] = NSNumber(value: 0)
        applied[kSCPropNetProxiesExcludeSimpleHostnames as String] = NSNumber(value: 1)
        let existingExceptions = original[kSCPropNetProxiesExceptionsList as String] as? [String] ?? []
        applied[kSCPropNetProxiesExceptionsList as String] = Array(Set(existingExceptions + ["localhost", "127.0.0.1", "::1"])).sorted()

        serviceRecords[serviceID] = [
          "original": original,
          "applied": applied,
          "had_proxy_protocol": hadProxyProtocol,
        ]
        changes.append((proxyProtocol, applied))
      }
      guard !changes.isEmpty else {
        throw NSError(domain: "AeroVPN.SystemProxy", code: -2,
                      userInfo: [NSLocalizedDescriptionKey: "No configurable macOS network services were found"])
      }

      // Save recovery data before committing any system preference changes.
      UserDefaults.standard.set(["port": port, "services": serviceRecords], forKey: recoveryKey)
      for (proxyProtocol, configuration) in changes {
        guard SCNetworkProtocolSetConfiguration(proxyProtocol, configuration as CFDictionary) else {
          throw Self.configurationError("Could not set macOS HTTP/HTTPS proxy")
        }
      }
      guard SCPreferencesCommitChanges(preferences) else {
        throw Self.configurationError("Could not save macOS HTTP/HTTPS proxy")
      }
      guard SCPreferencesApplyChanges(preferences) else {
        throw Self.configurationError("Could not apply macOS HTTP/HTTPS proxy")
      }
    }
  }

  func restoreIfOwned() throws {
    guard let recovery = UserDefaults.standard.dictionary(forKey: recoveryKey),
          let serviceRecords = recovery["services"] as? [String: [String: Any]] else {
      UserDefaults.standard.removeObject(forKey: recoveryKey)
      return
    }

    try withPreferences { preferences in
      guard let currentSet = SCNetworkSetCopyCurrent(preferences),
            let services = SCNetworkSetCopyServices(currentSet) as? [SCNetworkService] else {
        throw Self.configurationError("Could not read macOS network services for proxy recovery")
      }

      var changed = false
      for service in services {
        guard let serviceID = SCNetworkServiceGetServiceID(service) as String?,
              let record = serviceRecords[serviceID],
              let original = record["original"] as? [String: Any],
              let applied = record["applied"] as? [String: Any],
              let proxyProtocol = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
              let current = SCNetworkProtocolGetConfiguration(proxyProtocol) as? [String: Any] else { continue }

        let hadProxyProtocol = record["had_proxy_protocol"] as? Bool ?? true
        if !hadProxyProtocol && managedKeys.allSatisfy({ Self.sameValue(current[$0], applied[$0]) }) {
          guard SCNetworkServiceRemoveProtocolType(service, kSCNetworkProtocolTypeProxies) else {
            throw Self.configurationError("Could not remove AeroVPN proxy settings")
          }
          changed = true
          continue
        }

        var restored = current
        for key in managedKeys where Self.sameValue(current[key], applied[key]) {
          if let oldValue = original[key] {
            restored[key] = oldValue
          } else {
            restored.removeValue(forKey: key)
          }
        }
        guard SCNetworkProtocolSetConfiguration(proxyProtocol, restored as CFDictionary) else {
          throw Self.configurationError("Could not restore previous macOS proxy settings")
        }
        changed = true
      }

      if changed {
        guard SCPreferencesCommitChanges(preferences) else {
          throw Self.configurationError("Could not save restored macOS proxy settings")
        }
        guard SCPreferencesApplyChanges(preferences) else {
          throw Self.configurationError("Could not apply restored macOS proxy settings")
        }
      }
    }
    UserDefaults.standard.removeObject(forKey: recoveryKey)
  }

  private func withPreferences<T>(_ body: (SCPreferences) throws -> T) throws -> T {
    var authorization: AuthorizationRef?
    let status = AuthorizationCreate(nil, nil, [], &authorization)
    guard status == errAuthorizationSuccess, let authorization else {
      throw NSError(domain: "AeroVPN.SystemProxy", code: Int(status),
                    userInfo: [NSLocalizedDescriptionKey: "Could not request permission to change macOS proxy settings"])
    }
    defer { AuthorizationFree(authorization, []) }
    let rightsFlags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
    let rightStatus = "system.services.systemconfiguration.network".withCString { rightName -> OSStatus in
      var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
      return withUnsafeMutablePointer(to: &item) { itemPointer in
        var rights = AuthorizationRights(count: 1, items: itemPointer)
        return AuthorizationCopyRights(authorization, &rights, nil, rightsFlags, nil)
      }
    }
    guard rightStatus == errAuthorizationSuccess else {
      throw NSError(domain: "AeroVPN.SystemProxy", code: Int(rightStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Administrator authorization was not granted for macOS network settings"])
    }
    guard let preferences = SCPreferencesCreateWithAuthorization(
      kCFAllocatorDefault, "AeroVPN" as CFString, nil, authorization
    ) else {
      throw Self.configurationError("Could not open macOS network preferences")
    }
    return try body(preferences)
  }

  private static func sameValue(_ left: Any?, _ right: Any?) -> Bool {
    if case .none = left, case .none = right { return true }
    guard let left, let right else { return false }
    if let left = left as? NSNumber, let right = right as? NSNumber { return left == right }
    if let left = left as? String, let right = right as? String { return left == right }
    if let left = left as? [String], let right = right as? [String] { return left == right }
    if let left = left as? NSObject { return left.isEqual(right) }
    return false
  }

  private static func configurationError(_ message: String) -> NSError {
    NSError(domain: "AeroVPN.SystemProxy", code: Int(SCError()),
            userInfo: [NSLocalizedDescriptionKey: "\(message) (SystemConfiguration error \(SCError()))"])
  }
}
