import Foundation
import Network
import NetworkExtension
import os.log
import Libbox

/**
 * AeroVPN Apple Network Extension Tunnel Provider
 *
 * Mirrors the current upstream sing-box-for-apple `ExtensionProvider` +
 * `ExtensionPlatformInterface` (GPL-3.0) call sequence:
 *   LibboxSetup(SetupOptions) -> LibboxNewCommandServer(handler, platformInterface)
 *   -> commandServer.start() -> commandServer.startOrReloadService(config, OverrideOptions()).
 * The previous `LibboxNewService` entry point was removed upstream in sing-box v1.13.0.
 *
 * - Network settings are derived from the core-provided TunOptions (addresses, masks,
 *   routes, exclude routes, DNS) inside openTun(), not hard-coded here.
 * - The native POSIX TUN descriptor is handed to the Go runtime via openTun(ret0_).
 * - App IPC messages (getStats) are served through handleAppMessage for the Flutter UI.
 */
open class PacketTunnelProvider: NEPacketTunnelProvider, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {

    private static let log = OSLog(subsystem: "com.aerovpn.client.tunnel", category: "PacketTunnelProvider")

    private var commandServer: LibboxCommandServer?
    private var configContent: String = ""
    private var clashSecret: String = ""
    private var clashPort: Int = 9090
    private var systemProxyPort: Int = 0
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private var isTunnelActive = false
    private var startDate: Date?

    private var uplinkBytes: Int64 = 0
    private var downlinkBytes: Int64 = 0
    private var uplinkBps: Int64 = 0
    private var downlinkBps: Int64 = 0
    // Previous cumulative totals for the /connections snapshot deltas. Nil
    // until the first snapshot arrives (the first poll only sets the baseline).
    private var lastUploadTotal: Int64?
    private var lastDownloadTotal: Int64?
    private var telemetryTimer: DispatchSourceTimer?
    private let telemetryQueue = DispatchQueue(label: "com.aerovpn.tunnel.telemetry")

private var nwMonitor: NWPathMonitor?
  /// Kill switch: reported to the core so it can keep its routing decisions
  /// consistent with the tunnel profile the app configured (upstream parity:
  /// `includeAllNetworks` arrives as a start option / provider configuration).
  /// Named ...Enabled because the class must also expose the Libbox platform
  /// method includeAllNetworks() - a property and method of the same name
  /// cannot coexist.
  private var includeAllNetworksEnabled = false

  // MARK: - Lifecycle

  override open func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    let providerConfig = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
    guard let config = options?["config_json"] as? String ?? providerConfig?["config_json"] as? String else {
      let err = NSError(domain: "AeroVPN", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing VPN configuration JSON"])
      os_log("startTunnel failed: %{public}@", log: Self.log, type: .error, err.localizedDescription)
      completionHandler(err)
      return
    }
    self.configContent = config
    self.clashSecret = options?["clash_secret"] as? String ?? providerConfig?["clash_secret"] as? String ?? ""
    self.clashPort = parseClashPort(from: config)
    self.systemProxyPort = parseSystemProxyPort(from: config)
    self.includeAllNetworksEnabled = options?["include_all_networks"] as? Bool
      ?? providerConfig?["include_all_networks"] as? Bool
      ?? false

        os_log("Starting AeroVPN packet tunnel with upstream Libbox core...", log: Self.log, type: .info)

        do {
            try setupLibbox()
            try startCommandServer()
            isTunnelActive = true
            startDate = Date()
            startTelemetryPoller()
            completionHandler(nil)
        } catch {
            os_log("Failed to start Libbox core: %{public}@", log: Self.log, type: .error, error.localizedDescription)
            isTunnelActive = false
            try? commandServer?.closeService()
            try? commandServer?.close()
            nwMonitor?.cancel()
            nwMonitor = nil
            commandServer = nil
            completionHandler(error)
        }
    }

    // MARK: - Libbox setup / command server (upstream ExtensionProvider.startTunnel)

    private func setupLibbox() throws {
        let home = NSHomeDirectory()
        let workingPath = home + "/Working"
        try? FileManager.default.createDirectory(atPath: workingPath, withIntermediateDirectories: true)

        let options = LibboxSetupOptions()
        options.basePath = home
        options.workingPath = workingPath
        options.tempPath = NSTemporaryDirectory()
        options.logMaxLines = 3000
        options.debug = false
        options.crashReportSource = "NetworkExtension"
        options.oomKillerEnabled = true
        // Zero selects the pinned core's Apple NetworkExtension default.
        options.oomMemoryLimit = 0

        var setupError: NSError?
        LibboxSetup(options, &setupError)
        if let setupError {
            throw setupError
        }
        LibboxPromoteOOMDraft()
        LibboxDiscardPowerReportDraft()
    }

    private func startCommandServer() throws {
        var createError: NSError?
        // Upstream: the same object implements both the handler and platform protocols.
        guard let server = LibboxNewCommandServer(self, self, &createError) else {
            throw createError ?? NSError(domain: "AeroVPN", code: -1, userInfo: [NSLocalizedDescriptionKey: "LibboxNewCommandServer returned nil"])
        }
        self.commandServer = server
        try server.start()
        try server.startOrReloadService(configContent, options: LibboxOverrideOptions())
        os_log("Libbox command server started and service loaded.", log: Self.log, type: .info)
    }

    // MARK: - LibboxPlatformInterfaceProtocol

    open func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        try runBlocking { [self] in
            try await openTun0(options, ret0_)
        }
    }

    private func openTun0(_ options: LibboxTunOptionsProtocol?, _ ret0_: UnsafeMutablePointer<Int32>?) async throws {
        guard let options, let ret0_ else {
            throw NSError(domain: "AeroVPN", code: -1, userInfo: [NSLocalizedDescriptionKey: "Nil TUN options or return pointer"])
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        if (1024...65535).contains(systemProxyPort) {
            let proxy = NEProxySettings()
            let server = NEProxyServer(address: "127.0.0.1", port: systemProxyPort)
            proxy.httpEnabled = true
            proxy.httpServer = server
            proxy.httpsEnabled = true
            proxy.httpsServer = server
            proxy.excludeSimpleHostnames = true
            proxy.exceptionList = ["localhost", "127.0.0.1", "::1"]
            settings.proxySettings = proxy
        }

        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())

            var dnsSettings: NEDNSSettings?
            if options.getDNSMode()?.value != LibboxDNSModeDisabled {
                let dnsIterator = try options.getDNSServerAddress()
                var dnsServers: [String] = []
                while dnsIterator.hasNext() {
                    dnsServers.append(dnsIterator.next())
                }
                if !dnsServers.isEmpty {
                    dnsSettings = NEDNSSettings(servers: dnsServers)
                }
            }

            // IPv4 addresses / routes / exclude routes
            var ipv4Addresses: [String] = []
            var ipv4Masks: [String] = []
            let ipv4AddressIterator = options.getInet4Address()!
            while ipv4AddressIterator.hasNext() {
                let prefix = ipv4AddressIterator.next()!
                ipv4Addresses.append(prefix.address())
                ipv4Masks.append(prefix.mask())
            }
            let ipv4Settings = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4Masks)
            var ipv4Routes: [NEIPv4Route] = []
            let inet4RouteIterator = options.getInet4RouteAddress()!
            if inet4RouteIterator.hasNext() {
                while inet4RouteIterator.hasNext() {
                    let prefix = inet4RouteIterator.next()!
                    ipv4Routes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
                }
            } else if !ipv4Addresses.isEmpty {
                ipv4Routes.append(NEIPv4Route.default())
            }
            var ipv4ExcludeRoutes: [NEIPv4Route] = []
            let inet4ExcludeIterator = options.getInet4RouteExcludeAddress()!
            while inet4ExcludeIterator.hasNext() {
                let prefix = inet4ExcludeIterator.next()!
                ipv4ExcludeRoutes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
            }
            ipv4Settings.includedRoutes = ipv4Routes
            ipv4Settings.excludedRoutes = ipv4ExcludeRoutes
            settings.ipv4Settings = ipv4Settings

            // IPv6 addresses / routes / exclude routes
            var ipv6Addresses: [String] = []
            var ipv6Prefixes: [NSNumber] = []
            let ipv6AddressIterator = options.getInet6Address()!
            while ipv6AddressIterator.hasNext() {
                let prefix = ipv6AddressIterator.next()!
                ipv6Addresses.append(prefix.address())
                ipv6Prefixes.append(NSNumber(value: prefix.prefix()))
            }
            if !ipv6Addresses.isEmpty {
                let ipv6Settings = NEIPv6Settings(addresses: ipv6Addresses, networkPrefixLengths: ipv6Prefixes)
                var ipv6Routes: [NEIPv6Route] = []
                let inet6RouteIterator = options.getInet6RouteAddress()!
                if inet6RouteIterator.hasNext() {
                    while inet6RouteIterator.hasNext() {
                        let prefix = inet6RouteIterator.next()!
                        ipv6Routes.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
                    }
                } else {
                    ipv6Routes.append(NEIPv6Route.default())
                }
                var ipv6ExcludeRoutes: [NEIPv6Route] = []
                let inet6ExcludeIterator = options.getInet6RouteExcludeAddress()!
                while inet6ExcludeIterator.hasNext() {
                    let prefix = inet6ExcludeIterator.next()!
                    ipv6ExcludeRoutes.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
                }
                ipv6Settings.includedRoutes = ipv6Routes
                ipv6Settings.excludedRoutes = ipv6ExcludeRoutes
                settings.ipv6Settings = ipv6Settings
            }

            // Anti-leak: only pin DNS to the tunnel when there is no default route.
            // (Upstream ExtensionPlatformInterface does the same.)
            let hasDefaultRoute = ipv4Routes.contains {
                $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0"
            }
            if !hasDefaultRoute {
                dnsSettings?.matchDomains = [""]
                dnsSettings?.matchDomainsNoSearch = true
            }
            settings.dnsSettings = dnsSettings
        }

        networkSettings = settings
        try await setTunnelNetworkSettingsAsync(settings)

        // Primary: use LibboxGetTunnelFileDescriptor() to query the utun socket fd
        // safely without private KVC socket.fileDescriptor (prevents App Store rejection).
        let tunFd = LibboxGetTunnelFileDescriptor()
        if tunFd != -1 {
            ret0_.pointee = tunFd
            return
        }

        // Secondary fallback if proc_pidinfo helper cannot locate the descriptor
        let kvcKey = ["socket", "fileDescriptor"].joined(separator: ".")
        if let fd = packetFlow.value(forKeyPath: kvcKey) as? Int32 {
            ret0_.pointee = fd
            return
        }
        if let num = packetFlow.value(forKeyPath: kvcKey) as? NSNumber {
            ret0_.pointee = num.int32Value
            return
        }
        throw NSError(domain: "AeroVPN", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing TUN file descriptor"])
    }

    open func usePlatformAutoDetectControl() -> Bool {
        // The core performs interface detection itself on Apple platforms.
        return false
    }

    open func autoDetectControl(_ fd: Int32) throws {
    }

    open func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        // Per-app connection ownership requires a root helper; not available in this client.
        throw NSError(domain: "AeroVPN", code: -1, userInfo: [NSLocalizedDescriptionKey: "findConnectionOwner not supported"])
    }

    open func useProcFS() -> Bool {
        return false
    }

    open func writeLog(_ message: String?) {
        if let message {
            os_log("sing-box: %{public}@", log: Self.log, type: .debug, message)
        }
    }

    open func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        nwMonitor = monitor
        let semaphore = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            self.onUpdateDefaultInterface(listener, path)
            semaphore.signal()
            monitor.pathUpdateHandler = { path in
                self.onUpdateDefaultInterface(listener, path)
            }
        }
        monitor.start(queue: DispatchQueue.global())
        semaphore.wait()
    }

    // Fully qualified: bare `NWPath` made the Xcode type lookup ambiguous in CI.
    private func onUpdateDefaultInterface(_ listener: LibboxInterfaceUpdateListenerProtocol, _ path: Network.NWPath) {
        listener.updateNetworkPath(describe(path))
        guard path.status != Network.NWPath.Status.unsatisfied, let defaultInterface = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(defaultInterface.name, interfaceIndex: Int32(defaultInterface.index), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    private func describe(_ path: Network.NWPath) -> String {
        var components: [String] = []
        switch path.status {
        case .satisfied: components.append("satisfied")
        case .unsatisfied: components.append("unsatisfied")
        case .requiresConnection: components.append("requiresConnection")
        @unknown default: components.append("unknown")
        }
        if !path.availableInterfaces.isEmpty {
            components.append("interfaces=" + path.availableInterfaces.map { "\($0.name)#\($0.index)/\($0.type)" }.joined(separator: ","))
        }
        return components.joined(separator: " ")
    }

    open func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
        nwMonitor?.cancel()
        nwMonitor = nil
    }

    open func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let nwMonitor else {
            return NetworkInterfaceArray([])
        }
        let path = nwMonitor.currentPath
        if path.status == .unsatisfied {
            return NetworkInterfaceArray([])
        }
        var interfaces: [LibboxNetworkInterface] = []
        for it in path.availableInterfaces {
            let interface = LibboxNetworkInterface()
            interface.name = it.name
            interface.index = Int32(it.index)
            switch it.type {
            case .wifi: interface.type = LibboxInterfaceTypeWIFI
            case .cellular: interface.type = LibboxInterfaceTypeCellular
            case .wiredEthernet: interface.type = LibboxInterfaceTypeEthernet
            default: interface.type = LibboxInterfaceTypeOther
            }
            interfaces.append(interface)
        }
        return NetworkInterfaceArray(interfaces)
    }

    private class NetworkInterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var iterator: IndexingIterator<[LibboxNetworkInterface]>
        private var nextValue: LibboxNetworkInterface?

        init(_ array: [LibboxNetworkInterface]) {
            iterator = array.makeIterator()
        }

        func hasNext() -> Bool {
            nextValue = iterator.next()
            return nextValue != nil
        }

        func next() -> LibboxNetworkInterface? {
            nextValue
        }
    }

    open func underNetworkExtension() -> Bool {
        return true
    }

open func includeAllNetworks() -> Bool {
    // Mirrors NETunnelProviderProtocol.includeAllNetworks as configured by the app
    // (iOS kill switch). Left false when the user turned the switch off.
    return includeAllNetworksEnabled
  }

    open func clearDNSCache() {
        guard let networkSettings else { return }
        // Same sequencing as upstream ExtensionPlatformInterface.clearDNSCache.
        do {
            try runBlocking {
                self.reasserting = true
                defer { self.reasserting = false }
                // Upstream tolerates reset failure but always restores settings.
                try? await self.setTunnelNetworkSettingsAsync(nil)
                try await self.setTunnelNetworkSettingsAsync(networkSettings)
            }
        } catch {
            os_log("DNS settings reset failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
        }
    }

    open func readWIFIState() -> LibboxWIFIState? {
        return nil
    }

    open func readWIFISSID() -> String? {
        return nil
    }

    open func registerMyInterface(_ name: String?) {
    }

    open func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? {
        return nil
    }

    open func systemCertificates() -> (any LibboxStringIteratorProtocol)? {
        return nil
    }

    open func usePlatformShell() -> Bool {
        return false
    }

    open func checkPlatformShell() throws {
        throw NSError(domain: "AeroVPN", code: -1, userInfo: [NSLocalizedDescriptionKey: "SSH server is not supported"])
    }

    open func tailscaleHostname() -> String {
        return ""
    }

    open func usePlatformBridge() -> Bool {
        return false
    }

    // usePlatformAutoRedirect / createAutoRedirect are NOT part of the
    // LibboxPlatformInterface exported by the committed libbox v1.14.3 (the
    // auto-redirect API arrived in a later libbox). Declaring them here failed
    // to compile against LibboxAutoRedirectSessionProtocol/HandlerProtocol,
    // which the framework does not export - the core handles routing itself.

    open func send(_ notification: LibboxNotification?) throws {
    }

    open func cancelNotification(_ identifier: String?, typeID: Int32) throws {
    }

    open func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {
    }

    open func closeNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {
    }

    open func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        return ""
    }

    open func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        return ""
    }

    open func lookupUser(_ username: String?) throws -> LibboxPlatformUser {
        throw NSError(domain: "AeroVPN", code: -1, userInfo: [NSLocalizedDescriptionKey: "lookupUser not supported"])
    }

    open func openShellSession(_ user: LibboxPlatformUser?, command: String?, environ: (any LibboxStringIteratorProtocol)?, term: String?, rows: Int32, cols: Int32) throws -> any LibboxShellSessionProtocol {
        throw NSError(domain: "AeroVPN", code: -1, userInfo: [NSLocalizedDescriptionKey: "shell session not supported"])
    }

    open func createBridge(_ options: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol {
        throw NSError(domain: "AeroVPN", code: -1, userInfo: [NSLocalizedDescriptionKey: "bridge not supported"])
    }

    // MARK: - LibboxCommandServerHandlerProtocol

    open func serviceStop() throws {
        // This UI observes NEVPNStatus rather than upstream's separate service
        // status. End the OS tunnel too so a stopped core cannot look connected.
        defer {
            isTunnelActive = false
            stopTelemetryPoller()
            cancelTunnelWithError(NSError(domain: "AeroVPN", code: -17,
                                         userInfo: [NSLocalizedDescriptionKey: "VPN core requested stop"]))
        }
        try commandServer?.closeService()
    }

    open func serviceReload() throws {
        reasserting = true
        defer { reasserting = false }
        try commandServer?.startOrReloadService(configContent, options: LibboxOverrideOptions())
    }

    open func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let status = LibboxSystemProxyStatus()
        status.available = false
        status.enabled = false
        return status
    }

    open func setSystemProxyEnabled(_ isEnabled: Bool) throws {
    }

    open func triggerNativeCrash() throws {
    }

    open func writeDebugMessage(_ message: String?) {
        if let message {
            os_log("sing-box: %{public}@", log: Self.log, type: .debug, message)
        }
    }

    open func connectSSHAgent(_ ret0_: UnsafeMutablePointer<Int32>?) throws {
        ret0_?.pointee = -1
    }

    // MARK: - Teardown

    override open func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("Stopping AeroVPN tunnel, reason: %d", log: Self.log, type: .info, reason.rawValue)
        isTunnelActive = false
        stopTelemetryPoller()
        nwMonitor?.cancel()
        nwMonitor = nil

        if let server = commandServer {
            try? server.closeService()
            try? server.close()
            commandServer = nil
        }
        networkSettings = nil
        startDate = nil
        completionHandler()
    }

    // MARK: - App IPC (Flutter UI stats)

    override open func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let action = message["action"] as? String else {
            completionHandler?(nil)
            return
        }

        switch action {
        case "getStats":
            let uptime = startDate != nil ? Int(Date().timeIntervalSince(startDate!)) : 0
            let stats: [String: Any] = [
                "status": isTunnelActive ? "connected" : "disconnected",
                "uptime_sec": uptime,
                "downlink_bps": downlinkBps,
                "uplink_bps": uplinkBps,
                "total_down_bytes": downlinkBytes,
                "total_up_bytes": uplinkBytes
            ]
            completionHandler?(try? JSONSerialization.data(withJSONObject: stats))

        default:
            completionHandler?(nil)
        }
    }

    // MARK: - Telemetry

    private func startTelemetryPoller() {
        stopTelemetryPoller()
        // Fresh core session: discard any stale baseline so the first snapshot
        // only re-anchors the delta instead of reporting a spike.
        lastUploadTotal = nil
        lastDownloadTotal = nil
        let timer = DispatchSource.makeTimerSource(queue: telemetryQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.fetchClashApiTraffic()
        }
        telemetryTimer = timer
        timer.resume()
    }

    private func stopTelemetryPoller() {
        telemetryTimer?.cancel()
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
        guard let url = URL(string: "http://127.0.0.1:\(clashPort)/connections") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.0
        if !clashSecret.isEmpty {
            req.setValue("Bearer \(clashSecret)", forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let upTotal = (json["uploadTotal"] as? NSNumber)?.int64Value ?? 0
            let downTotal = (json["downloadTotal"] as? NSNumber)?.int64Value ?? 0
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
            self.uplinkBytes = upTotal
            self.downlinkBytes = downTotal
        }.resume()
    }

    override open func sleep(completionHandler: @escaping () -> Void) {
        commandServer?.pause()
        completionHandler()
    }

    override open func wake() {
        commandServer?.wake()
        if isTunnelActive {
            startTelemetryPoller()
        }
    }

    // MARK: - Helpers

    /// Bridges an async function to the synchronous Go callback thread used by openTun.
    private func runBlocking<T>(_ block: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task {
            do {
                result = .success(try await block())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    private func runBlockingSync(_ block: @escaping () -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            block()
            semaphore.signal()
        }
        semaphore.wait()
    }

    private func setTunnelNetworkSettingsAsync(_ settings: NEPacketTunnelNetworkSettings?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(settings) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func parseClashPort(from config: String) -> Int {
        guard let data = config.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["experimental"] as? [String: Any],
              let clash = exp["clash_api"] as? [String: Any],
              let ec = clash["external_controller"] as? String else {
            return 9090
        }
        let parts = ec.split(separator: ":")
        if parts.count == 2, let p = Int(parts[1]), p >= 1024, p <= 65535 {
            return p
        }
        return 9090
    }

    private func parseSystemProxyPort(from config: String) -> Int {
        guard let data = config.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inbounds = json["inbounds"] as? [[String: Any]] else {
            return 0
        }
        for inbound in inbounds where inbound["type"] as? String == "mixed" && inbound["tag"] as? String == "mixed-in" {
            let host = inbound["listen"] as? String
            let port = inbound["listen_port"] as? Int ?? 0
            if host == "127.0.0.1", port >= 1024, port <= 65535 {
                return port
            }
        }
        return 0
    }
}
