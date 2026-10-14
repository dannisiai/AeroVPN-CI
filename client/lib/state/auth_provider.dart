import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import '../core/api/api_client.dart';
import '../core/api/api_models.dart';
import '../core/security/secure_vault.dart';
import '../core/vpn/method_channel_vpn_service.dart';

class AuthProvider extends ChangeNotifier {
  final ApiClient _apiClient;
  final SecureVault _vault;

  bool _isLoading = false;
  String? _errorMessage;
  UserModel? _user;
  bool _isAuthenticated = false;
  Future<void>? _logoutInFlight;

  /// Called at the start of logout so the tunnel owner (VpnProvider) can stop
  /// a live tunnel and revoke its connect session while the access token is
  /// still valid. AuthProvider stays decoupled from VpnProvider.
  Future<void> Function()? onLogoutTeardown;

  AuthProvider(this._apiClient, this._vault) {
    _apiClient.onTokenUpdate = (newAccess, newRefresh) async {
      final session = await _vault.getDeviceSessionId() ?? '';
      await _vault.saveTokens(
        accessToken: newAccess,
        refreshToken: newRefresh,
        deviceSessionId: session,
      );
    };

    _apiClient.onSessionExpired = () {
      unawaited(logout());
    };
  }

  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  UserModel? get user => _user;
  bool get isAuthenticated => _isAuthenticated;

  Future<void> restoreSession() async {
    _isLoading = true;
    notifyListeners();

    try {
      final access = await _vault.getAccessToken();
      final refresh = await _vault.getRefreshToken();

      if (access != null && access.isNotEmpty) {
        _apiClient.setTokens(accessToken: access, refreshToken: refresh);
        // Cached identity keeps an offline restart usable. Account/plan data
        // is refreshed separately and never invented as an active subscription.
        _user = UserModel(
          id: 'usr_me',
          email: await _vault.getSavedEmail() ?? '',
          planStatus: 'unknown',
        );
        _isAuthenticated = true;
        final plan = await _apiClient.getAccount();
        _user = UserModel(
          id: 'usr_me',
          email: await _vault.getSavedEmail() ?? '',
          planStatus: plan.status,
        );
        _isAuthenticated = true;
      }
    } catch (error) {
      if (error is ApiException && error.statusCode == 401) {
        // Expiry uses the same awaited teardown as a manual logout. Keep
        // tunnel controls visible if stopping the native service fails.
        await logout();
      } else {
        _errorMessage = '账号状态暂时无法刷新，请重试：$error';
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> login(String email, String password) async {
    _setLoading(true);
    _errorMessage = null;

    try {
      // Stable per-install device id: the control plane binds connect sessions
      // (and max_devices accounting) to the login session's device identity.
      final deviceId = await _vault.getOrCreateDeviceId();
      final res = await _apiClient.login(
        email,
        password,
        deviceInfo: {
          'device_name': 'AeroVPN Client (${Platform.operatingSystem})',
          'os': Platform.operatingSystem,
          'device_id': deviceId,
        },
      );
      _user = res.user;
      _isAuthenticated = true;

      _apiClient.setTokens(
        accessToken: res.accessToken,
        refreshToken: res.refreshToken,
      );

      await _vault.saveTokens(
        accessToken: res.accessToken,
        refreshToken: res.refreshToken,
        deviceSessionId: res.deviceSessionId,
      );
      await _vault.saveEmail(email);

      _setLoading(false);
      return true;
    } catch (e) {
      _errorMessage = e is ApiException ? e.message : 'Login failed: $e';
      _setLoading(false);
      return false;
    }
  }

  Future<bool> sendVerificationCode(String email) async {
    _setLoading(true);
    _errorMessage = null;

    try {
      await _apiClient.sendVerificationCode(email);
      _setLoading(false);
      return true;
    } catch (e) {
      _errorMessage = e is ApiException ? e.message : '发送验证码失败: $e';
      _setLoading(false);
      return false;
    }
  }

  Future<bool> register(String email, String password, String code) async {
    _setLoading(true);
    _errorMessage = null;

    try {
      await _apiClient.register(email, password, code);
      _setLoading(false);
      return true;
    } catch (e) {
      _errorMessage = e is ApiException ? e.message : '注册失败: $e';
      _setLoading(false);
      return false;
    }
  }

  Future<bool> forgotPassword(String email) async {
    _setLoading(true);
    _errorMessage = null;
    try {
      await _apiClient.forgotPassword(email);
      _setLoading(false);
      return true;
    } catch (e) {
      _errorMessage = e is ApiException ? e.message : 'Request failed: $e';
      _setLoading(false);
      return false;
    }
  }

  Future<bool> resetPassword(String email, String code, String newPassword) async {
    _setLoading(true);
    _errorMessage = null;
    try {
      await _apiClient.resetPassword(email, code, newPassword);
      _setLoading(false);
      return true;
    } catch (e) {
      _errorMessage = e is ApiException ? e.message : 'Reset failed: $e';
      _setLoading(false);
      return false;
    }
  }

  Future<void> logout() => _logoutInFlight ??= _performLogout().whenComplete(() {
    _logoutInFlight = null;
  });

  Future<void> _performLogout() async {
    try {
      // Stop a live tunnel and revoke its connect session FIRST: both need a
      // still-valid access token. A failed stop must remain controllable and
      // must not be hidden by switching to the login screen.
      await onLogoutTeardown?.call();
    } catch (error) {
      _errorMessage = 'VPN 尚未停止，退出登录未完成：$error';
      notifyListeners();
      return;
    }
    // Server-side revocation of the login session; failures never block logout.
    try {
      await _apiClient.logout();
    } catch (_) {}
    _apiClient.clearTokens();
    // Purge the native VPN profile: it stores node credentials in the tunnel
    // provider configuration, which must not outlive the session. AuthProvider
    // has no VpnService dependency, and the method-channel service is
    // stateless with removeVpnProfile() being a silent no-op on platforms
    // without the native handler, so a direct instance suffices here.
    try {
      await MethodChannelVpnService().removeVpnProfile();
    } catch (_) {
      // Best-effort only: profile cleanup must never block or fail logout.
    }
    await _vault.clearAuthData();
    _user = null;
    _isAuthenticated = false;
    notifyListeners();
  }

  void _setLoading(bool val) {
    _isLoading = val;
    notifyListeners();
  }
}
