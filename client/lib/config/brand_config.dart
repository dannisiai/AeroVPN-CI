/// White-label Configuration for AeroVPN
/// Auto-generated from config/whitelabel.json.
class BrandConfig {
  static const String appName = 'AeroVPN';
  static const String brandName = 'AeroVPN Network';
  static const String appId = 'com.aerovpn.client';
  static const String bundleId = 'com.aerovpn.client';
  static const String version = '1.0.0';
  static const int buildNumber = 100;
  static const String companyName = 'Aero Technologies Inc.';

  // Embedded hardcoded API Base URL
  static const String apiBaseUrl = 'https://www.ethworldcupcoin.xyz:8443';
  static const Duration apiTimeout = Duration(milliseconds: 15000);

  // Ordered fallback API base URLs tried when the primary is unreachable.
  // Keep this list in whitelabel.json only - do not hardcode domains elsewhere.
  static const List<String> apiFallbackBaseUrls = <String>[];

  // Domains routed through the direct (non-tunnel) outbound: the control plane
  // itself plus any brand-owned properties. Consumed by SingboxConfigBuilder.
  // The trailing ".cn" entry is a routing policy choice owned by this config.
  static const List<String> directDomains = <String>['ethworldcupcoin.xyz', 'aerovpn.com', 'api.aerovpn.com', '.cn'];

  // Official Support & Legal URLs
  static const String websiteUrl = 'https://www.aerovpn.com';
  static const String supportUrl = 'https://support.aerovpn.com';
  static const String privacyPolicyUrl = 'https://www.aerovpn.com/privacy';
  static const String termsOfServiceUrl = 'https://www.aerovpn.com/terms';

  // Privileged Daemon IPC Endpoint (for Windows/Desktop)
  static const String daemonIpcUrl = 'http://127.0.0.1:9527';
}
