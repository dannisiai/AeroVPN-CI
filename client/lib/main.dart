import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'config/app_theme.dart';
import 'config/brand_config.dart';
import 'core/api/api_client.dart';
import 'core/security/secure_vault.dart';
import 'core/vpn/platform_vpn_service.dart';
import 'state/account_provider.dart';
import 'state/auth_provider.dart';
import 'state/locale_provider.dart';
import 'state/region_provider.dart';
import 'state/vpn_provider.dart';
import 'ui/auth/login_screen.dart';
import 'ui/widgets/app_scaffold.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final vault = SecureVault();
  await vault.init();

  final apiClient = ApiClient(baseUrl: BrandConfig.apiBaseUrl);
  final vpnService = PlatformVpnService.create(daemonUrl: BrandConfig.daemonIpcUrl);
  final authProvider = AuthProvider(apiClient, vault);
  final vpnProvider = VpnProvider(apiClient, vpnService, vault);
  // Logout must stop a live tunnel and revoke its connect session while the
  // access token still works; VpnProvider owns that teardown.
  authProvider.onLogoutTeardown = () => vpnProvider.disconnect();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => LocaleProvider(vault)),
        ChangeNotifierProvider.value(value: authProvider),
        ChangeNotifierProvider(create: (_) => AccountProvider(apiClient)),
        ChangeNotifierProvider(create: (_) => RegionProvider(apiClient)),
        ChangeNotifierProvider.value(value: vpnProvider),
      ],
      child: const AeroVpnApp(),
    ),
  );
}

class AeroVpnApp extends StatefulWidget {
  const AeroVpnApp({super.key});

  @override
  State<AeroVpnApp> createState() => _AeroVpnAppState();
}

class _AeroVpnAppState extends State<AeroVpnApp> with WidgetsBindingObserver {
  static const MethodChannel _trayChannel = MethodChannel('aerovpn/tray');
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _trayChannel.setMethodCallHandler(_handleTrayMethodCall);
    _bootstrap();
  }

  Future<Object?> _handleTrayMethodCall(MethodCall call) async {
    if (call.method != 'requestExit') {
      throw MissingPluginException('Unsupported AeroVPN tray method: ${call.method}');
    }
    try {
      await context.read<VpnProvider>().disconnect();
      return true;
    } catch (_) {
      // The native runner restores the window so the disconnect error remains
      // visible and the user can retry instead of silently leaving a tunnel up.
      return false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<VpnProvider>().refreshStatus();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _trayChannel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final localeProv = context.read<LocaleProvider>();
    final authProv = context.read<AuthProvider>();
    final vpnProv = context.read<VpnProvider>();
    final accountProv = context.read<AccountProvider>();
    final regionProv = context.read<RegionProvider>();

    await localeProv.initLocale();
    await vpnProv.initPreferences();
    await authProv.restoreSession();

    if (authProv.isAuthenticated) {
      await Future.wait([
        accountProv.fetchAccount(),
        regionProv.fetchRegions(),
      ]);

      if (vpnProv.autoConnect && vpnProv.isDisconnected && !vpnProv.isBusy) {
        final best = regionProv.getFastestTarget();
        vpnProv.connect(region: best.region, city: best.city);
      }
    }

    if (mounted) {
      setState(() => _initialized = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return MaterialApp(
      title: BrandConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      home: !_initialized
          ? const Scaffold(
              body: Center(
                child: CircularProgressIndicator(color: AppTheme.primary),
              ),
            )
          : (auth.isAuthenticated ? const AppScaffold() : const LoginScreen()),
    );
  }
}
