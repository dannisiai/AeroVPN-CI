import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aerovpn_client/config/brand_config.dart';
import 'package:aerovpn_client/core/api/api_models.dart';
import 'package:aerovpn_client/core/engine/singbox_config_builder.dart';

/// Regression tests for the pre-launch fixes:
///  - dual-stack TUN (IPv6 leak guard)
///  - vless SNI must come from the control plane (no invented default)
///  - hysteria2 bandwidth comes from the node spec, not hardcoded values
///  - direct-routed domains come from BrandConfig (single source of truth)
void main() {
  ConnectResponse connect({
    String protocol = 'vless',
    Map<String, dynamic>? tls,
    int? upMbps,
    int? downMbps,
  }) {
    return ConnectResponse(
      sessionId: 'ephem_regression',
      regionId: 'us',
      cityId: 'us-1',
      cityName: 'Node 1',
      countryName: 'United States',
      countryCode: 'US',
      virtualIp: '198.51.100.42',
      expiresAt: 1728189000,
      ttlSeconds: 3600,
      protocol: protocol,
      nodeSpec: EphemeralNodeSpec(
        server: 'us.relay.example.net',
        serverPort: protocol == 'hysteria2' ? 9443 : 443,
        uuid: protocol == 'vless' ? '944bbc33-9de8-408e-975c-31742f6eb571' : null,
        password: protocol == 'hysteria2' ? 'hy2pass' : null,
        tls: tls,
        upMbps: upMbps,
        downMbps: downMbps,
      ),
    );
  }

  group('IPv6 leak guard', () {
    test('TUN inbound is provisioned dual-stack', () {
      final config = jsonDecode(SingboxConfigBuilder.buildConfig(
        connectData: connect(tls: {'enabled': true, 'server_name': 'gw.example.net'}),
      )) as Map<String, dynamic>;

      final tun = (config['inbounds'] as List).first as Map<String, dynamic>;
      final addresses = (tun['address'] as List).cast<String>();
      expect(addresses, contains('172.19.0.1/30'));
      expect(addresses, contains(SingboxConfigBuilder.tunAddressV6),
          reason: 'without a v6 TUN address there is no v6 default route and '
              'IPv6 traffic bypasses the VPN on Android');
    });

    test('loop-reject rule also covers the IPv6 TUN subnet', () {
      final config = jsonDecode(SingboxConfigBuilder.buildConfig(
        connectData: connect(tls: {'enabled': true, 'server_name': 'gw.example.net'}),
      )) as Map<String, dynamic>;

      final rules = (config['route']['rules'] as List).cast<Map>();
      final rejectRule = rules.firstWhere((r) => r['action'] == 'reject');
      expect((rejectRule['ip_cidr'] as List), contains('fdfe:dcba:9876::/126'));
    });
  });

  group('vless SNI provenance', () {
    test('missing node_spec.tls.server_name is a diagnostic error, not a silent default', () {
      expect(
        () => SingboxConfigBuilder.buildConfig(connectData: connect(tls: {'enabled': true})),
        throwsArgumentError,
        reason: 'an invented SNI (the old gateway.cloudflare.com fallback) makes '
            'the node silently unreachable or probeable',
      );
    });

    test('provided server_name is used verbatim', () {
      final config = jsonDecode(SingboxConfigBuilder.buildConfig(
        connectData: connect(tls: {'enabled': true, 'server_name': 'real-sni.example.net'}),
      )) as Map<String, dynamic>;
      final proxy = (config['outbounds'] as List).first as Map<String, dynamic>;
      expect(proxy['tls']['server_name'], equals('real-sni.example.net'));
    });
  });

  group('hysteria2 bandwidth', () {
    test('bandwidth is taken from the node spec', () {
      final config = jsonDecode(SingboxConfigBuilder.buildConfig(
        connectData: connect(
          protocol: 'hysteria2',
          tls: {'enabled': true, 'server_name': 'hy2.example.net'},
          upMbps: 50,
          downMbps: 300,
        ),
      )) as Map<String, dynamic>;
      final proxy = (config['outbounds'] as List).first as Map<String, dynamic>;
      expect(proxy['up_mbps'], equals(50));
      expect(proxy['down_mbps'], equals(300));
    });

    test('no hardcoded bandwidth when the spec has none (core default = BBR)', () {
      final config = jsonDecode(SingboxConfigBuilder.buildConfig(
        connectData: connect(protocol: 'hysteria2', tls: {'enabled': true, 'server_name': 'hy2.example.net'}),
      )) as Map<String, dynamic>;
      final proxy = (config['outbounds'] as List).first as Map<String, dynamic>;
      expect(proxy.containsKey('up_mbps'), isFalse,
          reason: 'a hardcoded up/down forces Brutal congestion control with '
              'wrong rates; omitting them keeps upstream BBR defaults');
      expect(proxy.containsKey('down_mbps'), isFalse);
    });
  });

  group('single source of truth for domains', () {
    test('direct-routed domains come from BrandConfig, no stale literals', () {
      final config = jsonDecode(SingboxConfigBuilder.buildConfig(
        connectData: connect(tls: {'enabled': true, 'server_name': 'gw.example.net'}),
      )) as Map<String, dynamic>;

      final dnsDomains = ((config['dns']['rules'] as List).first
          as Map)['domain_suffix'] as List;
      expect(dnsDomains, equals(BrandConfig.directDomains));

      final routeRules = (config['route']['rules'] as List).cast<Map>();
      final bypass = routeRules
          .firstWhere((r) => r.containsKey('domain_suffix') && r['outbound'] == 'direct');
      expect((bypass['domain_suffix'] as List), equals(BrandConfig.directDomains));

      // The old invented SNI default must not appear anywhere in the document.
      expect(jsonEncode(config), isNot(contains('gateway.cloudflare.com')));
    });
  });

  group('Clash API port configuration', () {
    test('custom clashPort is emitted in external_controller', () {
      final config = jsonDecode(SingboxConfigBuilder.buildConfig(
        connectData: connect(tls: {'enabled': true, 'server_name': 'gw.example.net'}),
        clashPort: 9095,
      )) as Map<String, dynamic>;

      final ec = config['experimental']['clash_api']['external_controller'];
      expect(ec, equals('127.0.0.1:9095'));
    });

    test('default clashPort is 9090 when unspecified', () {
      final config = jsonDecode(SingboxConfigBuilder.buildConfig(
        connectData: connect(tls: {'enabled': true, 'server_name': 'gw.example.net'}),
      )) as Map<String, dynamic>;

      final ec = config['experimental']['clash_api']['external_controller'];
      expect(ec, equals('127.0.0.1:9090'));
    });

    test('findAvailablePort returns a valid unprivileged port', () async {
      final port = await SingboxConfigBuilder.findAvailablePort();
      expect(port, greaterThanOrEqualTo(1024));
      expect(port, lessThanOrEqualTo(65535));
    });
  });
}
