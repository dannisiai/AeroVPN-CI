import 'dart:convert';
import 'dart:io';
import 'dart:math';
import '../../config/brand_config.dart';
import '../api/api_models.dart';

/// In-Memory sing-box Configuration Generator
/// Translates short-lived EphemeralNodeSpec received from official API
/// into standard official sing-box v1.14 JSON configuration.
///
/// Compatibility baseline is the pinned core (see `scripts/fetch_upstream_cores.*`,
/// `UPSTREAM_VERSION`): sing-box v1.14.3. Do NOT reintroduce options this version
/// rejects - sing-box fails hard on removed options instead of ignoring them:
/// - `inbound.sniff` / `sniff_override_destination` were REMOVED in v1.13.0
///   (initializing such an inbound aborts with "legacy inbound fields ... removed").
///   Protocol sniffing is now a route rule action, see the `{'action': 'sniff'}`
///   rule in [buildConfig]; without it, tun-mode connections carry only an IP and
///   every `domain_suffix` route rule silently stops matching.
/// - `geosite` / `geoip` rule items were REMOVED in v1.12.0 (rule creation aborts).
///   Replace with `rule_set` referencing `.srs` files if CN bypass is needed.
/// - `independent_cache` (v1.14.0) and `inbound.stack` (v1.15.0) are deprecated;
///   the DNS cache is independent by default, so the option is simply omitted.
/// - The WireGuard **outbound** was REMOVED in v1.13.0 in favour of a WireGuard
///   **endpoint** (`endpoints`, referenced by tag from route rules / `route.final`).
///
/// IPv6: the TUN is provisioned dual-stack (v4 + the upstream example ULA
/// `fdfe:dcba:9876::1/126`). With `auto_route` the core derives a `::/0` route
/// for it (sing-tun `BuildAutoRouteRanges`), so literal-IPv6 and stale-AAAA
/// connections are captured by the VPN instead of bypassing it; the DNS
/// `ipv4_only` strategy keeps AAAA answers empty so normal traffic stays on the
/// v4 path. If an exit cannot reach IPv6, such connections fail closed inside
/// the tunnel rather than leaking around it.
///
/// CRITICAL SECURITY NOTE:
/// This configuration is constructed entirely in RAM by the mobile hosts;
/// the desktop hosts additionally hand it to the official core as a runtime
/// config file / process stdin (see platform host sources for the exact path).
/// Raw VPN secrets (UUID, passwords, private keys) are never persisted by this
/// builder itself. The Windows daemon additionally enforces a strict whitelist
/// on this exact document shape before starting the core (core/daemon/config_guard.go),
/// so keep builder output and that schema in sync.
///
/// Upstream parity: sing-box `experimental.clash_api` supports an optional
/// `secret` for loopback telemetry auth. Following upstream SFA/SFI practice,
/// callers MUST supply a per-session random secret; an empty secret leaves
/// 127.0.0.1:9090 unauthenticated. [buildConfig] auto-generates a 32-hex-char
/// secret when none is provided (never silently disables auth).
class SingboxConfigBuilder {
  /// IPv6 ULA for the TUN, taken from the upstream sing-box config examples
  /// (`option/tun.go` address examples). Pairs with 172.19.0.1/30.
  static const String tunAddressV6 = 'fdfe:dcba:9876::1/126';
  static const int defaultClashApiPort = 9090;

  /// Generate a 16-byte (32 hex char) per-session Clash API secret.
  static String generateClashSecret() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Attempts to bind to [defaultPort] on loopback. If unavailable, finds an available ephemeral port.
  static Future<int> findAvailablePort({int defaultPort = defaultClashApiPort}) async {
    try {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, defaultPort);
      final port = socket.port;
      await socket.close();
      if (port >= 1024 && port <= 65535) return port;
      return defaultPort;
    } catch (_) {
      try {
        final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = socket.port;
        await socket.close();
        if (port >= 1024 && port <= 65535) return port;
        return defaultPort;
      } catch (_) {
        return defaultPort;
      }
    }
  }

  /// Build full sing-box JSON configuration string
  static String buildConfig({
    required ConnectResponse connectData,
    bool bypassLocalLan = true,
    bool strictRoute = true,
    bool useGVisorStack = false,
    String clashSecret = '',
    int clashPort = defaultClashApiPort,
    bool systemProxy = false,
    int systemProxyPort = 2080,
    bool systemProxyWithTun = false,
  }) {
    // Upstream hardening: never leave clash_api unauthenticated on loopback.
    var effectiveSecret = clashSecret;
    if (effectiveSecret.isEmpty) {
      effectiveSecret = generateClashSecret();
    }
    final spec = connectData.nodeSpec;
    final includeTun = !systemProxy || systemProxyWithTun;
    final protocol = connectData.protocol.toLowerCase();
    // Single source of truth for direct-routed domains: config/whitelabel.json
    // via BrandConfig (regenerate with scripts/sync_whitelabel.js).
    final directDomains = BrandConfig.directDomains;

    // 1. Build proxy outbound / endpoint for the ephemeral node.
    //    WireGuard is an endpoint since sing-box v1.13.0; every other protocol
    //    stays a regular outbound.
    final bool isWireguard = protocol == 'wireguard';
    final Map<String, dynamic>? proxyEndpoint =
        isWireguard ? _buildWireguardEndpoint(spec) : null;
    final Map<String, dynamic>? proxyOutbound;
    switch (protocol) {
      case 'wireguard':
        proxyOutbound = null;
        break;
      case 'vless':
        proxyOutbound = _buildVlessOutbound(spec);
        break;
      case 'trojan':
        proxyOutbound = _buildTrojanOutbound(spec);
        break;
      case 'hysteria2':
        proxyOutbound = _buildHysteria2Outbound(spec);
        break;
      default:
        proxyOutbound = _buildVlessOutbound(spec);
    }

    // 2. Full sing-box v1.14+ JSON structure
    final Map<String, dynamic> config = {
      'log': {
        'level': 'warn',
        'timestamp': true,
      },
      'experimental': {
        'clash_api': {
          'external_controller': '127.0.0.1:$clashPort',
          // Per-session random secret (see [generateClashSecret]).
          // Telemetry pollers must present `Authorization: Bearer <secret>`.
          'secret': effectiveSecret,
        },
      },
      'dns': {
        'servers': [
          {
            'type': 'udp',
            'tag': 'dns-remote',
            'server': '1.1.1.1',
            'detour': 'proxy',
          },
          {
            'type': 'local',
            'tag': 'dns-direct',
            'detour': 'direct',
          },
        ],
        'rules': [
          {
            'domain_suffix': directDomains,
            'server': 'dns-direct',
          },
        ],
        'final': 'dns-remote',
        'strategy': 'ipv4_only',
      },
      'inbounds': [
        if (systemProxy)
          {
            'type': 'mixed',
            'tag': 'mixed-in',
            'listen': '127.0.0.1',
            'listen_port': systemProxyPort,
          },
        if (includeTun)
        {
          'type': 'tun',
          'tag': 'tun-in',
          // Darwin only accepts utunN. Omitting the name lets the pinned core
          // select an available utun device instead of rejecting "tun0".
          if (!Platform.isMacOS) 'interface_name': 'tun0',
          'address': [
            '172.19.0.1/30',
            tunAddressV6,
          ],
          'auto_route': true,
          // TUN routing and DNS handling while the core is running. This does
          // not implement a Windows firewall Kill Switch after the core exits.
          'strict_route': strictRoute,
          // Apple's includeAllNetworks requires a stack other than mixed/system.
          // Keep mixed as the default on other platforms for existing behavior.
          'stack': useGVisorStack ? 'gvisor' : 'mixed',
          'exclude_interface': [
            'tun0',
            'wintun',
            'Tailscale',
            'WireGuard',
          ],
        }
      ],
      'outbounds': [
        if (proxyOutbound != null) proxyOutbound,
        {
          'type': 'direct',
          'tag': 'direct',
        },
      ],
      // WireGuard lives here since sing-box v1.13.0. The endpoint tag is a valid
      // target for route rules and `route.final` exactly like an outbound tag.
      if (proxyEndpoint != null) 'endpoints': [proxyEndpoint],
      'route': {
        'default_domain_resolver': 'dns-direct',
        'rules': [
          // Must run before anything that matches on domain, and before the DNS
          // hijack: sniffing is what turns a tun destination into a domain name.
          {
            'action': 'sniff',
          },
          {
            'protocol': 'dns',
            'action': 'hijack-dns',
          },
          // Never send traffic addressed to this TUN's own subnet back out via
          // direct. Upstream reports a Windows TUN -> direct -> same-TUN loop
          // for the peer address (sing-box#4415/#4455); reject it before LAN bypass.
          if (includeTun) {
            'inbound': ['tun-in'],
            'ip_cidr': ['172.19.0.0/30', 'fdfe:dcba:9876::/126'],
            'action': 'reject',
            'method': 'drop',
          },
          if (bypassLocalLan)
            {
              'ip_is_private': true,
              'outbound': 'direct',
            },
          {
            'domain_suffix': directDomains,
            'outbound': 'direct',
          },
        ],
        'final': 'proxy',
        'auto_detect_interface': true,
      }
    };

    return jsonEncode(config);
  }

  static Map<String, dynamic> _buildVlessOutbound(EphemeralNodeSpec spec) {
    final tls = spec.tls ?? const {};
    final serverName = tls['server_name'] as String?;
    if (serverName == null || serverName.isEmpty) {
      // The SNI is part of the server identity (especially for Reality);
      // inventing a default here would make the node silently unreachable or,
      // worse, probeable. The control plane MUST send it.
      throw ArgumentError(
          'node_spec.tls.server_name is missing for vless node ${spec.server}; '
          'the control plane must provide it explicitly');
    }
    return {
      'type': 'vless',
      'tag': 'proxy',
      'server': spec.server,
      'server_port': spec.serverPort,
      'uuid': spec.uuid ?? '',
      'flow': spec.flow ?? 'xtls-rprx-vision',
      'tls': {
        'enabled': true,
        'server_name': serverName,
        'utls': {
          'enabled': true,
          'fingerprint': 'chrome',
        },
        if (tls['reality'] != null)
          'reality': {
            'enabled': true,
            'public_key': tls['reality']['public_key'],
            'short_id': tls['reality']['short_id'],
          }
      },
      'packet_encoding': 'xudp',
    };
  }

  static Map<String, dynamic> _buildTrojanOutbound(EphemeralNodeSpec spec) {
    return {
      'type': 'trojan',
      'tag': 'proxy',
      'server': spec.server,
      'server_port': spec.serverPort,
      'password': spec.password ?? '',
      'tls': {
        'enabled': true,
        // SNI defaults to the connect host itself, which is always valid.
        'server_name': spec.tls?['server_name'] ?? spec.server,
        'utls': {
          'enabled': true,
          'fingerprint': 'chrome',
        }
      },
      'multiplex': {
        'enabled': true,
        'max_connections': 4,
        'min_streams': 4,
        'padding': true,
      }
    };
  }

  /// WireGuard as an *endpoint* (sing-box v1.13.0+ removed the WireGuard outbound).
  /// Field names follow upstream `option.WireGuardEndpointOptions`:
  /// `address` / `private_key` / `mtu` / `peers[].{address,port,public_key,reserved,allowed_ips}`.
  static Map<String, dynamic> _buildWireguardEndpoint(EphemeralNodeSpec spec) {
    final wg = spec.wireguard ?? {};
    return {
      'type': 'wireguard',
      'tag': 'proxy',
      'system': false,
      'mtu': 1420,
      'address': wg['address'] ?? ['10.66.66.2/32'],
      'private_key': wg['private_key'] ?? '',
      'peers': [
        {
          'address': spec.server,
          'port': spec.serverPort,
          'public_key': wg['public_key'] ?? '',
          'reserved': wg['reserved'] ?? [0, 0, 0],
          'allowed_ips': ['0.0.0.0/0', '::/0'],
          'persistent_keepalive_interval': 25,
        }
      ],
    };
  }

  static Map<String, dynamic> _buildHysteria2Outbound(EphemeralNodeSpec spec) {
    final obfs = spec.obfs ?? (spec.tls?['obfs'] as Map<String, dynamic>?);
    return {
      'type': 'hysteria2',
      'tag': 'proxy',
      'server': spec.server,
      'server_port': spec.serverPort,
      'password': spec.password ?? '',
      'tls': {
        'enabled': true,
        // SNI defaults to the connect host itself, which is always valid.
        'server_name': spec.tls?['server_name'] ?? spec.server,
      },
      if (obfs != null)
        'obfs': {
          'type': obfs['type'] ?? 'salamander',
          'password': obfs['password'] ?? '',
        },
      // Bandwidth must come from the node spec (server-side capacity data).
      // Omitting both lets sing-box use its default BBR congestion control;
      // hardcoding client-side values would force Brutal with wrong rates.
      if ((spec.upMbps ?? 0) > 0) 'up_mbps': spec.upMbps,
      if ((spec.downMbps ?? 0) > 0) 'down_mbps': spec.downMbps,
    };
  }
}
