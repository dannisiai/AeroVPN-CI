import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:aerovpn_client/config/brand_config.dart';
import 'package:aerovpn_client/core/api/api_models.dart';
import 'package:aerovpn_client/core/engine/singbox_config_builder.dart';

void main() {
  group('Commercial VPN Architecture & Engine Tests', () {
    test('BrandConfig maintains embedded security and branding invariants', () {
      expect(BrandConfig.appName, equals('AeroVPN'));
      expect(BrandConfig.apiBaseUrl, isNotEmpty);
      expect(BrandConfig.bundleId, equals('com.aerovpn.client'));
    });

    test('SingboxConfigBuilder transforms ephemeral VLESS-Reality credentials into valid sing-box JSON in memory', () {
      final mockResponse = ConnectResponse(
        sessionId: 'ephem_test_123',
        regionId: 'us',
        cityId: 'us-nyc',
        cityName: 'New York',
        countryName: 'United States',
        countryCode: 'US',
        virtualIp: '198.51.100.42',
        expiresAt: 1728189000,
        ttlSeconds: 3600,
        protocol: 'vless',
        nodeSpec: EphemeralNodeSpec(
          server: 'us-nyc.relay.aerovpn.net',
          serverPort: 443,
          uuid: '944bbc33-9de8-408e-975c-31742f6eb571',
          flow: 'xtls-rprx-vision',
          tls: {
            'enabled': true,
            'server_name': 'gateway.cloudflare.com',
            'reality': {
              'public_key': 'b9k7L_1oBqvG6fRz2X3mNk7l8P9q0R1s2T3u4V5w6X8',
              'short_id': 'ed1e740b',
            }
          },
        ),
      );

      final jsonString = SingboxConfigBuilder.buildConfig(
        connectData: mockResponse,
        bypassLocalLan: true,
        strictRoute: true,
      );

      expect(jsonString, isNotEmpty);
      final config = jsonDecode(jsonString) as Map<String, dynamic>;

      // Verify Inbound is TUN
      final inbounds = config['inbounds'] as List;
      expect(inbounds.first['type'], equals('tun'));
      expect(inbounds.first['strict_route'], isTrue);

      // Verify Outbounds contain ephemeral proxy
      final outbounds = config['outbounds'] as List;
      final proxyOutbound = outbounds.first as Map<String, dynamic>;
      expect(proxyOutbound['type'], equals('vless'));
      expect(proxyOutbound['server'], equals('us-nyc.relay.aerovpn.net'));
      expect(proxyOutbound['uuid'], equals('944bbc33-9de8-408e-975c-31742f6eb571'));
      expect(proxyOutbound['tls']['reality']['public_key'], equals('b9k7L_1oBqvG6fRz2X3mNk7l8P9q0R1s2T3u4V5w6X8'));

      // Verify DNS leak protection
      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['final'], equals('dns-remote'));
    });

    test('SingboxConfigBuilder transforms WireGuard credentials properly', () {
      final mockResponse = ConnectResponse(
        sessionId: 'ephem_wg_999',
        regionId: 'jp',
        cityId: 'jp-tyo',
        cityName: 'Tokyo',
        countryName: 'Japan',
        countryCode: 'JP',
        virtualIp: '198.51.100.88',
        expiresAt: 1728189000,
        ttlSeconds: 3600,
        protocol: 'wireguard',
        nodeSpec: EphemeralNodeSpec(
          server: 'jp-tyo.relay.aerovpn.net',
          serverPort: 51820,
          wireguard: {
            'private_key': 'aGVsbG93b3JsZA==',
            'public_key': 'c2luZ2JveGtpbmc=',
            'address': ['10.66.66.2/32'],
          },
        ),
      );

      final jsonString = SingboxConfigBuilder.buildConfig(connectData: mockResponse);
      final config = jsonDecode(jsonString) as Map<String, dynamic>;

      // WireGuard is an endpoint since sing-box v1.13.0 (the outbound was removed
      // upstream and is rejected by the pinned core), so it must NOT appear in
      // `outbounds` and the route target tag must resolve through `endpoints`.
      final outbounds = config['outbounds'] as List;
      expect(outbounds.any((o) => (o as Map)['type'] == 'wireguard'), isFalse);

      final endpoints = config['endpoints'] as List;
      final proxyEndpoint = endpoints.first as Map<String, dynamic>;
      expect(proxyEndpoint['type'], equals('wireguard'));
      expect(proxyEndpoint['tag'], equals('proxy'));
      expect(proxyEndpoint['private_key'], equals('aGVsbG93b3JsZA=='));

      final peer = (proxyEndpoint['peers'] as List).first as Map<String, dynamic>;
      expect(peer['address'], equals('jp-tyo.relay.aerovpn.net'));
      expect(peer['port'], equals(51820));
      expect(peer['public_key'], equals('c2luZ2JveGtpbmc='));
      expect(peer['allowed_ips'], contains('0.0.0.0/0'));

      expect(config['route']['final'], equals('proxy'));
    });

    test('SingboxConfigBuilder omits geosite/geoip (removed upstream) and legacy sniff options', () {
      final mockResponse = ConnectResponse(
        sessionId: 'ephem_test_safe',
        regionId: 'us',
        cityId: 'us-nyc',
        cityName: 'New York',
        countryName: 'United States',
        countryCode: 'US',
        virtualIp: '198.51.100.42',
        expiresAt: 1728189000,
        ttlSeconds: 3600,
        protocol: 'vless',
        nodeSpec: EphemeralNodeSpec(
          server: 'us.relay.aerovpn.net',
          serverPort: 443,
          // vless requires an explicit SNI from the control plane; the builder
          // refuses to invent one (see singbox_config_builder_regression_test).
          tls: {'enabled': true, 'server_name': 'us.relay.aerovpn.net'},
        ),
      );

      final jsonDefault = SingboxConfigBuilder.buildConfig(connectData: mockResponse);
      final configDefault = jsonDecode(jsonDefault) as Map<String, dynamic>;

      // geosite/geoip rule items were removed in sing-box 1.12.0 and abort rule
      // creation, so they must never be emitted.
      final dnsRules = configDefault['dns']['rules'] as List;
      for (final rule in dnsRules) {
        expect((rule as Map).containsKey('geosite'), isFalse);
      }

      final routeRules = configDefault['route']['rules'] as List;
      for (final rule in routeRules) {
        expect((rule as Map).containsKey('geosite'), isFalse);
        expect(rule.containsKey('geoip'), isFalse);
      }

      // Route rules should contain ip_is_private and domain_suffix with .cn
      final hasPrivateIp = routeRules.any((r) => (r as Map)['ip_is_private'] == true);
      final hasCnDomain = routeRules.any((r) => ((r as Map)['domain_suffix'] as List?)?.contains('.cn') == true);
      expect(hasPrivateIp, isTrue);
      expect(hasCnDomain, isTrue);

      // `inbound.sniff`/`sniff_override_destination` were removed in sing-box
      // 1.13.0 (config is rejected at runtime), sniffing must be a route action
      // placed before the DNS hijack rule so domain rules still match.
      final tunInbound = (configDefault['inbounds'] as List).first as Map<String, dynamic>;
      expect(tunInbound.containsKey('sniff'), isFalse);
      expect(tunInbound.containsKey('sniff_override_destination'), isFalse);
      final firstRouteRule = routeRules.first as Map;
      expect(firstRouteRule['action'], equals('sniff'));

      // `independent_cache` is deprecated in sing-box 1.14.0 (cache is always
      // independent now) and `block` was removed as a special outbound.
      expect(configDefault['dns'].containsKey('independent_cache'), isFalse);
      final outboundTypes = (configDefault['outbounds'] as List)
          .map((o) => (o as Map)['type'])
          .toList();
      expect(outboundTypes.contains('block'), isFalse);
    });

    test('PlanModel correctly computes active status and remaining days', () {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final plan = PlanModel(
        id: 'pro_annual',
        name: 'Pro Unlimited',
        status: 'active',
        expiresAt: nowSec + 30 * 86400,
        maxDevices: 5,
        currentDevices: 2,
      );

      expect(plan.isActive, isTrue);
      expect(plan.remainingDays, greaterThanOrEqualTo(29));
    });
  });
}
