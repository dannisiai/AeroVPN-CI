/**
 * AeroVPN White-label Synchronization Tool
 * Synchronizes single-source-of-truth config/whitelabel.json
 * to all client platform targets (Flutter Dart, Android, Apple, Windows).
 */

const fs = require('fs');
const path = require('path');

const rootDir = path.resolve(__dirname, '..');
const configPath = path.join(rootDir, 'config', 'whitelabel.json');

if (!fs.existsSync(configPath)) {
  console.error('Error: config/whitelabel.json not found!');
  process.exit(1);
}

const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
const { brand, api } = config;

function dartStringList(values) {
  return (values || []).map((v) => `'${v}'`).join(', ');
}

console.log(`==> Synchronizing white-label configuration for: ${brand.app_name} (${brand.brand_name})`);

// 1. Sync client/lib/config/brand_config.dart
const brandConfigDartPath = path.join(rootDir, 'client', 'lib', 'config', 'brand_config.dart');
const dartContent = `/// White-label Configuration for ${brand.app_name}
/// Auto-generated from config/whitelabel.json.
class BrandConfig {
  static const String appName = '${brand.app_name}';
  static const String brandName = '${brand.brand_name}';
  static const String appId = '${brand.app_id}';
  static const String bundleId = '${brand.bundle_id}';
  static const String version = '${brand.version}';
  static const int buildNumber = ${brand.build_number};
  static const String companyName = '${brand.company_name}';

  // Embedded hardcoded API Base URL
  static const String apiBaseUrl = '${api.api_base_url}';
  static const Duration apiTimeout = Duration(milliseconds: ${api.api_timeout_ms});

  // Ordered fallback API base URLs tried when the primary is unreachable.
  // Keep this list in whitelabel.json only - do not hardcode domains elsewhere.
  static const List<String> apiFallbackBaseUrls = <String>[${dartStringList(api.fallback_base_urls)}];

  // Domains routed through the direct (non-tunnel) outbound: the control plane
  // itself plus any brand-owned properties. Consumed by SingboxConfigBuilder.
  // The trailing ".cn" entry is a routing policy choice owned by this config.
  static const List<String> directDomains = <String>[${dartStringList(api.direct_domains)}];

  // Official Support & Legal URLs
  static const String websiteUrl = '${brand.website}';
  static const String supportUrl = '${brand.support_url}';
  static const String privacyPolicyUrl = '${brand.privacy_policy_url}';
  static const String termsOfServiceUrl = '${brand.terms_of_service_url}';

  // Privileged Daemon IPC Endpoint (for Windows/Desktop)
  static const String daemonIpcUrl = 'http://127.0.0.1:9527';
}
`;
fs.writeFileSync(brandConfigDartPath, dartContent, 'utf8');
console.log(`[OK] Synchronized: ${brandConfigDartPath}`);

console.log('==> White-label brand synchronization finished successfully.');
