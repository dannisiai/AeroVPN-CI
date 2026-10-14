import Flutter
import UIKit
import NetworkExtension

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let CHANNEL = "com.aerovpn.client/vpn"
  private var vpnManager: NETunnelProviderManager?
  private var currentIp = ""
  private var currentCountry = ""
  private var currentCity = ""
  private var connectedDate: Date?
  private var isChannelConfigured = false
  private var preferencesLoaded = false
  private var preferencesLoading = false
  private var preferenceLoadError: Error?
  private var preferenceWaiters: [() -> Void] = []

  /// Kill switch state (iOS: `includeAllNetworks` + an on-demand connect rule).
  /// Persisted because the system can start the tunnel without this app running.
  private static let killSwitchDefaultsKey = "aerovpn.killSwitch"
  private var killSwitchEnabled = true

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    loadKillSwitchPreference()
    loadVpnPreferences()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // UIScene creates the UI after didFinishLaunchingWithOptions. Use the engine
  // registrar as documented by Flutter instead of reading AppDelegate.window.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    setupMethodChannel(messenger: engineBridge.applicationRegistrar.messenger())
  }

  // MARK: - Kill switch
  //
  // iOS has no firewall to toggle. Upstream sing-box-for-apple implements the
  // equivalent behaviour with NETunnelProviderProtocol.includeAllNetworks plus an
  // NEOnDemandRuleConnect rule (so the tunnel comes back after a drop and traffic
  // cannot escape outside it). The extension also reports the value through
  // `includeAllNetworks()`, which is fed by the `include_all_networks` start option.

  private func loadKillSwitchPreference() {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: Self.killSwitchDefaultsKey) == nil {
      // Product default (config/whitelabel.json: kill_switch_enabled = true).
      killSwitchEnabled = true
    } else {
      killSwitchEnabled = defaults.bool(forKey: Self.killSwitchDefaultsKey)
    }
  }

  private func applyKillSwitch(_ enabled: Bool, completion: @escaping (Error?) -> Void) {
    guard let manager = vpnManager else {
      completion(NSError(domain: "AeroVPN", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "VPN profile is not ready yet"]))
      return
    }

    guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
      completion(NSError(domain: "AeroVPN", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "VPN profile has no packet tunnel configuration"]))
      return
    }

    let tunnelStatus = manager.connection.status
    let tunnelWasActive = tunnelStatus != .disconnected && tunnelStatus != .invalid
    var configForRestart: String?
    var clashSecretForRestart = ""
    proto.includeAllNetworks = enabled
    var providerConfig = proto.providerConfiguration ?? [:]
    if let configJson = providerConfig["config_json"] as? String {
      guard let updatedConfig = updatingTunConfig(configJson, killSwitchEnabled: enabled) else {
        completion(NSError(domain: "AeroVPN", code: -3,
                           userInfo: [NSLocalizedDescriptionKey: "Could not update the saved tunnel configuration"]))
        return
      }
      // On-demand starts use this saved JSON after the app is no longer running.
      // Keep the sing-box TUN stack and route policy aligned with includeAllNetworks.
      providerConfig["config_json"] = updatedConfig
      configForRestart = updatedConfig
      clashSecretForRestart = providerConfig["clash_secret"] as? String ?? ""
    } else if tunnelWasActive {
      completion(NSError(domain: "AeroVPN", code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "Active tunnel has no saved configuration to restart"]))
      return
    }
    providerConfig["include_all_networks"] = enabled
    proto.providerConfiguration = providerConfig
    manager.protocolConfiguration = proto

    manager.isOnDemandEnabled = enabled
    if enabled {
      // NEOnDemandRuleConnect ignores probeURL (only evaluateConnection rules
      // evaluate it), so no probe is set here.
      let rule = NEOnDemandRuleConnect()
      rule.interfaceTypeMatch = .any
      manager.onDemandRules = [rule]
    } else {
      manager.onDemandRules = []
    }

    manager.saveToPreferences { [weak self] error in
      guard let self = self else {
        completion(error)
        return
      }
      if error == nil {
        UserDefaults.standard.set(enabled, forKey: Self.killSwitchDefaultsKey)
        self.killSwitchEnabled = enabled
      }
      guard error == nil else {
        completion(error)
        return
      }
      guard tunnelWasActive, let configJson = configForRestart else {
        completion(nil)
        return
      }
      self.restartActiveTunnel(manager: manager,
                               configJson: configJson,
                               clashSecret: clashSecretForRestart,
                               includeAllNetworks: enabled,
                               completion: completion)
    }
  }

  private func restartActiveTunnel(manager: NETunnelProviderManager,
                                   configJson: String,
                                   clashSecret: String,
                                   includeAllNetworks: Bool,
                                   completion: @escaping (Error?) -> Void) {
    manager.loadFromPreferences { [weak self] error in
      guard let self = self else {
        completion(NSError(domain: "AeroVPN", code: -9,
                           userInfo: [NSLocalizedDescriptionKey: "VPN controller was released while restarting the tunnel"]))
        return
      }
      guard error == nil else {
        completion(error)
        return
      }
      guard let session = manager.connection as? NETunnelProviderSession else {
        completion(NSError(domain: "AeroVPN", code: -5,
                           userInfo: [NSLocalizedDescriptionKey: "VPN tunnel session is unavailable"]))
        return
      }

      session.stopVPNTunnel()
      self.waitForTunnelStop(session: session,
                             configJson: configJson,
                             clashSecret: clashSecret,
                             includeAllNetworks: includeAllNetworks,
                             attemptsRemaining: 40,
                             sawDisconnecting: false,
                             completion: completion)
    }
  }

  private func waitForTunnelStop(session: NETunnelProviderSession,
                                 configJson: String,
                                 clashSecret: String,
                                 includeAllNetworks: Bool,
                                 attemptsRemaining: Int,
                                 sawDisconnecting: Bool,
                                 completion: @escaping (Error?) -> Void) {
    switch session.status {
    case .disconnected:
      do {
        try session.startVPNTunnel(options: [
          "config_json": configJson as NSObject,
          "clash_secret": clashSecret as NSObject,
          "include_all_networks": includeAllNetworks as NSObject,
        ])
        connectedDate = Date()
        completion(nil)
      } catch {
        connectedDate = nil
        completion(error)
      }
    case .connected where sawDisconnecting:
      // On-demand may have restarted the extension with the saved configuration.
      connectedDate = Date()
      completion(nil)
    case .disconnecting:
      if attemptsRemaining == 0 {
        completion(NSError(domain: "AeroVPN", code: -6,
                           userInfo: [NSLocalizedDescriptionKey: "Timed out restarting the VPN tunnel"]))
      } else {
        scheduleTunnelRestartCheck(session: session,
                                   configJson: configJson,
                                   clashSecret: clashSecret,
                                   includeAllNetworks: includeAllNetworks,
                                   attemptsRemaining: attemptsRemaining - 1,
                                   sawDisconnecting: true,
                                   completion: completion)
      }
    case .connecting, .connected, .reasserting:
      if attemptsRemaining == 0 {
        completion(NSError(domain: "AeroVPN", code: -6,
                           userInfo: [NSLocalizedDescriptionKey: "Timed out restarting the VPN tunnel"]))
      } else {
        scheduleTunnelRestartCheck(session: session,
                                   configJson: configJson,
                                   clashSecret: clashSecret,
                                   includeAllNetworks: includeAllNetworks,
                                   attemptsRemaining: attemptsRemaining - 1,
                                   sawDisconnecting: sawDisconnecting,
                                   completion: completion)
      }
    case .invalid:
      completion(NSError(domain: "AeroVPN", code: -7,
                         userInfo: [NSLocalizedDescriptionKey: "VPN session became invalid while restarting"]))
    @unknown default:
      completion(NSError(domain: "AeroVPN", code: -8,
                         userInfo: [NSLocalizedDescriptionKey: "VPN session entered an unknown state while restarting"]))
    }
  }

  private func scheduleTunnelRestartCheck(session: NETunnelProviderSession,
                                          configJson: String,
                                          clashSecret: String,
                                          includeAllNetworks: Bool,
                                          attemptsRemaining: Int,
                                          sawDisconnecting: Bool,
                                          completion: @escaping (Error?) -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self = self else {
        completion(NSError(domain: "AeroVPN", code: -10,
                           userInfo: [NSLocalizedDescriptionKey: "VPN controller was released while checking tunnel restart"]))
        return
      }
      self.waitForTunnelStop(session: session,
                             configJson: configJson,
                             clashSecret: clashSecret,
                             includeAllNetworks: includeAllNetworks,
                             attemptsRemaining: attemptsRemaining,
                             sawDisconnecting: sawDisconnecting,
                             completion: completion)
    }
  }

  private func updatingTunConfig(_ configJson: String, killSwitchEnabled: Bool) -> String? {
    guard let data = configJson.data(using: .utf8),
          var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var inbounds = config["inbounds"] as? [[String: Any]] else {
      return nil
    }

    var foundTunInbound = false
    for index in inbounds.indices where inbounds[index]["type"] as? String == "tun" {
      inbounds[index]["stack"] = killSwitchEnabled ? "gvisor" : "mixed"
      inbounds[index]["strict_route"] = killSwitchEnabled
      foundTunInbound = true
    }
    guard foundTunInbound else { return nil }

    config["inbounds"] = inbounds
    guard let updatedData = try? JSONSerialization.data(withJSONObject: config),
          let updatedJson = String(data: updatedData, encoding: .utf8) else {
      return nil
    }
    return updatedJson
  }

  private func setupMethodChannel(messenger: FlutterBinaryMessenger) {
    guard !isChannelConfigured else { return }
    isChannelConfigured = true
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
        let clashSecret = args["clash_secret"] as? String ?? ""
        let killSwitch = args["kill_switch"] as? Bool ?? true

        self.startTunnel(configJson: configJson, clashSecret: clashSecret, killSwitch: killSwitch, completion: { error in
          if let error = error {
            result(FlutterError(code: "START_FAILED", message: error.localizedDescription, details: nil))
          } else {
            self.connectedDate = Date()
            result(["status": self.currentStatusString()])
          }
        })

      case "stopTunnel":
        // The result is deferred until the on-demand rules are cleared and the
        // session actually stopped; a failure must surface to the UI instead of
        // reporting "disconnected" while the kill switch revives the tunnel.
        self.stopTunnel { error in
          if let error = error {
            result(FlutterError(code: "STOP_FAILED", message: error.localizedDescription, details: nil))
          } else {
            self.connectedDate = nil
            result(["status": "disconnected"])
          }
        }

      case "getStatus":
        let status = self.currentStatusString()
        result(["status": status, "running": status == "connected"])

      case "getStats":
        self.sendStats(result: result)
      case "setKillSwitch":
        let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? true
        // Apply it to the tunnel profile (includeAllNetworks + on-demand), not just
        // to the UI state: a switch that reports success without changing the tunnel
        // is exactly the bug this replaces.
        self.loadVpnPreferences {
          self.applyKillSwitch(enabled) { error in
            if let error = error {
              result(FlutterError(code: "KILL_SWITCH_FAILED",
                                  message: error.localizedDescription, details: nil))
            } else {
              result(["kill_switch": enabled, "applied": true])
            }
          }
        }

      case "removeVpnProfile":
        // Best-effort purge on logout: the saved profile keeps node credentials
        // in its provider configuration, so a logged-out user must not keep it.
        // Only a fatal preference-load error reaches Flutter; per-profile
        // failures are logged and swallowed so logout never fails here.
        self.removeVpnProfile { error in
          if let error = error {
            result(FlutterError(code: "REMOVE_PROFILE_FAILED",
                                message: error.localizedDescription, details: nil))
          } else {
            result(["removed": true])
          }
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func sendStats(result: @escaping FlutterResult) {
    if !preferencesLoaded {
      loadVpnPreferences {
        if let error = self.preferenceLoadError {
          result(FlutterError(code: "VPN_STATE_FAILED", message: error.localizedDescription, details: nil))
        } else {
          self.sendStats(result: result)
        }
      }
      return
    }
    let status = currentStatusString()
    let date = vpnManager?.connection.connectedDate ?? connectedDate
    var payload: [String: Any] = [
      "status": status, "assigned_ip": currentIp, "country": currentCountry, "city": currentCity,
      "uptime_sec": date.map { Int(Date().timeIntervalSince($0)) } ?? 0,
      "kill_switch": killSwitchEnabled, "downlink_bps": 0, "uplink_bps": 0,
      "total_down_bytes": 0, "total_up_bytes": 0,
    ]
    guard let session = vpnManager?.connection as? NETunnelProviderSession, status == "connected",
          let request = try? JSONSerialization.data(withJSONObject: ["action": "getStats"]) else {
      result(payload)
      return
    }
    // A provider IPC error or missing callback must not stall the Flutter poller.
    var answered = false
    let complete: (Data?) -> Void = { data in
      DispatchQueue.main.async {
        guard !answered else { return }
        answered = true
        if let data = data,
           let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
          for key in ["downlink_bps", "uplink_bps", "total_down_bytes", "total_up_bytes"] {
            payload[key] = response[key] ?? 0
          }
        }
        result(payload)
      }
    }
    do { try session.sendProviderMessage(request, responseHandler: complete) }
    catch { complete(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { complete(nil) }
  }

  private func loadVpnPreferences(completion: (() -> Void)? = nil) {
    if let completion = completion { preferenceWaiters.append(completion) }
    guard !preferencesLoading else { return }
    preferencesLoading = true
    NETunnelProviderManager.loadAllFromPreferences { [weak self] (managers, error) in
      guard let self = self else { return }
      self.preferenceLoadError = error
      self.preferencesLoaded = error == nil
      if error == nil {
        if let existing = managers?.first(where: {
          ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier ==
            "com.aerovpn.aerovpnClient.PacketTunnel"
        }) {
          self.vpnManager = existing
          let status = existing.connection.status
          if status != .invalid && status != .disconnected {
            let proto = existing.protocolConfiguration as? NETunnelProviderProtocol
            let saved = proto?.providerConfiguration
            self.currentIp = saved?["assigned_ip"] as? String ?? self.currentIp
            self.currentCountry = saved?["country"] as? String ?? self.currentCountry
            self.currentCity = saved?["city"] as? String ?? self.currentCity
            self.killSwitchEnabled = proto?.includeAllNetworks ?? self.killSwitchEnabled
            self.connectedDate = existing.connection.connectedDate
          }
        } else {
          let manager = NETunnelProviderManager()
          let proto = NETunnelProviderProtocol()
          proto.providerBundleIdentifier = "com.aerovpn.aerovpnClient.PacketTunnel"
          proto.serverAddress = "AeroVPN Gateway"
          manager.protocolConfiguration = proto
          manager.localizedDescription = "AeroVPN"
          manager.isEnabled = true
          self.vpnManager = manager
        }
      }
      self.preferencesLoading = false
      let callbacks = self.preferenceWaiters
      self.preferenceWaiters.removeAll()
      callbacks.forEach { $0() }
    }
  }
  private func startTunnel(configJson: String, clashSecret: String = "", killSwitch: Bool, completion: @escaping (Error?) -> Void) {
    loadVpnPreferences { [weak self] in
      guard let self = self, let manager = self.vpnManager else {
        completion(NSError(domain: "AeroVPN", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load VPN manager"]))
        return
      }

      if let error = self.preferenceLoadError { completion(error); return }
      self.killSwitchEnabled = killSwitch
      let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
      proto.providerBundleIdentifier = "com.aerovpn.aerovpnClient.PacketTunnel"
      proto.serverAddress = "AeroVPN Gateway"
      // The node credentials (config_json, clash_secret) are persisted in the
      // tunnel profile's provider configuration. Trade-off: the NetworkExtension
      // must be able to start while this app is not running (kill switch /
      // on-demand reconnects), and the profile is the only storage it can read
      // then. Upstream sing-box-for-apple makes the same choice: its
      // ExtensionProvider.persistStartOptions writes the start options
      // (including the config content) to disk for the extension. Logging out
      // drops the profile and its credentials (removeVpnProfile).
      proto.providerConfiguration = [
        "config_json": configJson,
        "clash_secret": clashSecret,
        "assigned_ip": currentIp,
        "country": currentCountry,
        "city": currentCity,
        // Consumed by PacketTunnelProvider.includeAllNetworks().
        "include_all_networks": killSwitchEnabled,
      ]
      // Keep the tunnel profile itself in sync with the kill switch selection.
      proto.includeAllNetworks = killSwitchEnabled

      manager.protocolConfiguration = proto
      manager.localizedDescription = "AeroVPN"
      manager.isEnabled = true
      // Re-arm the kill switch on-demand rule according to the preference: a
      // manual stopTunnel clears it (so the system cannot revive the tunnel),
      // and a reconnect with the kill switch on must restore it.
      manager.isOnDemandEnabled = killSwitchEnabled
      if killSwitchEnabled {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        manager.onDemandRules = [rule]
      } else {
        manager.onDemandRules = []
      }

      manager.saveToPreferences { error in
        if let error = error {
          completion(error)
          return
        }

        UserDefaults.standard.set(killSwitch, forKey: Self.killSwitchDefaultsKey)
        manager.loadFromPreferences { error in
          if let error = error {
            completion(error)
            return
          }

          do {
            try manager.connection.startVPNTunnel(options: [
              "config_json": configJson as NSObject,
              "clash_secret": clashSecret as NSObject,
              "include_all_networks": self.killSwitchEnabled as NSObject,
            ])
            self.waitForTunnelStart(manager: manager, attempts: 60, sawConnecting: false,
                                    completion: completion)
          } catch {
            completion(error)
          }
        }
      }
    }
  }

  private func waitForTunnelStart(manager: NETunnelProviderManager,
                                  attempts: Int,
                                  sawConnecting: Bool,
                                  completion: @escaping (Error?) -> Void) {
    let status = manager.connection.status
    if status == .connected { completion(nil); return }
    if status == .invalid || (status == .disconnected && sawConnecting) || attempts == 0 {
      completion(NSError(domain: "AeroVPN", code: -16,
                         userInfo: [NSLocalizedDescriptionKey: "VPN extension failed to connect (status \(status.rawValue))"]))
      return
    }
    let observedConnecting = sawConnecting || status == .connecting || status == .reasserting
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      self.waitForTunnelStart(manager: manager, attempts: attempts - 1,
                              sawConnecting: observedConnecting, completion: completion)
    }
  }

  /// Stops the tunnel and makes the stop stick. While the kill switch is on, the
  /// profile carries an on-demand connect rule, so stopping the session alone
  /// makes the system reconnect immediately: the UI shows "disconnected" while
  /// the tunnel quietly comes back up. The on-demand rule is therefore cleared
  /// and persisted BEFORE the session is stopped; the next startTunnel call
  /// re-arms it according to the kill switch preference.
  private func stopTunnel(completion: @escaping (Error?) -> Void) {
    if !preferencesLoaded {
      loadVpnPreferences {
        if let error = self.preferenceLoadError { completion(error) }
        else { self.stopTunnel(completion: completion) }
      }
      return
    }
    guard let manager = vpnManager else {
      completion(nil)
      return
    }
    let status = manager.connection.status
    if (status == .disconnected || status == .invalid) && !manager.isOnDemandEnabled {
      // Idle profile: nothing to stop, and no live session for an on-demand
      // rule to revive.
      completion(nil)
      return
    }
    // Reload the persisted profile first: the in-memory controller may be
    // stale, and the on-demand state that revives the tunnel is the persisted one.
    manager.loadFromPreferences { [weak self] error in
      guard let self = self else {
        completion(NSError(domain: "AeroVPN", code: -12,
                           userInfo: [NSLocalizedDescriptionKey: "VPN controller was released while stopping the tunnel"]))
        return
      }
      if let error = error {
        completion(error)
        return
      }
      manager.isOnDemandEnabled = false
      manager.onDemandRules = []
      manager.saveToPreferences { error in
        if let error = error {
          // Without a successful save the system may re-arm the tunnel after
          // the stop, so do not report success.
          completion(error)
          return
        }
        // Save first, stop second: only once the system has accepted the
        // on-demand removal can the session be dropped without being revived.
        manager.connection.stopVPNTunnel()
        self.waitForTunnelDisconnect(manager: manager,
                                     attemptsRemaining: 40,
                                     completion: completion)
      }
    }
  }

  /// Reports completion only once the session actually reached a stopped state
  /// (or timed out), so the UI "disconnected" result matches the system state.
  private func waitForTunnelDisconnect(manager: NETunnelProviderManager,
                                       attemptsRemaining: Int,
                                       completion: @escaping (Error?) -> Void) {
    let status = manager.connection.status
    if status == .disconnected || status == .invalid {
      completion(nil)
      return
    }
    if attemptsRemaining == 0 {
      completion(NSError(domain: "AeroVPN", code: -13,
                         userInfo: [NSLocalizedDescriptionKey: "Timed out stopping the VPN tunnel"]))
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self = self else {
        completion(NSError(domain: "AeroVPN", code: -12,
                           userInfo: [NSLocalizedDescriptionKey: "VPN controller was released while stopping the tunnel"]))
        return
      }
      self.waitForTunnelDisconnect(manager: manager,
                                   attemptsRemaining: attemptsRemaining - 1,
                                   completion: completion)
    }
  }

  /// Removes the saved VPN profile(s) owned by this app, dropping the node
  /// credentials kept in the tunnel provider configuration. Called on logout:
  /// a logged-out user keeps no profile, so no on-demand/always-on reconnect
  /// can bring the tunnel back. Best-effort — per-profile failures are logged
  /// and swallowed; only a fatal preference-load error reaches the caller.
  private func removeVpnProfile(completion: @escaping (Error?) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { [weak self] (managers, error) in
      guard let self = self else {
        completion(NSError(domain: "AeroVPN", code: -11,
                           userInfo: [NSLocalizedDescriptionKey: "VPN controller was released while removing the VPN profile"]))
        return
      }
      if let error = error {
        completion(error)
        return
      }
      for manager in managers ?? [] {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
              proto.providerBundleIdentifier == "com.aerovpn.aerovpnClient.PacketTunnel" else {
          continue
        }
        // Drop any live session first, then clear the stored credentials
        // before the profile itself disappears from preferences.
        manager.connection.stopVPNTunnel()
        proto.providerConfiguration = nil
        manager.protocolConfiguration = proto
        manager.removeFromPreferences { removeError in
          if let removeError = removeError {
            NSLog("AeroVPN: could not remove VPN profile: \(removeError.localizedDescription)")
          }
        }
      }
      // The cached controller may now point at a removed profile; drop it so
      // the next startTunnel rebuilds state from preferences.
      if let proto = self.vpnManager?.protocolConfiguration as? NETunnelProviderProtocol,
         proto.providerBundleIdentifier == "com.aerovpn.aerovpnClient.PacketTunnel" {
        self.vpnManager = nil
      }
      completion(nil)
    }
  }

  private func currentStatusString() -> String {
    guard let manager = vpnManager else { return "disconnected" }
    switch manager.connection.status {
    case .connected: return "connected"
    case .connecting: return "connecting"
    case .disconnecting: return "disconnecting"
    case .reasserting: return "reconnecting"
    default: return "disconnected"
    }
  }
}
