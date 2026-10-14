import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Secure Vault for Session Tokens & Device Credentials.
///
/// Fix (GitHub method: juliansteenbakker/flutter_secure_storage + VeryGoodOpenSource
/// static-security skill): SharedPreferences is plaintext (NSUserDefaults / XML) and
/// MUST NOT store tokens. Previous version stored access/refresh tokens in
/// SharedPreferences despite claiming Keychain/Keystore/Credential Locker.
///
/// Now: sensitive auth material -> FlutterSecureStorage (iOS Keychain, Android
/// Keystore, Windows Credential Locker, macOS Keychain, Linux libsecret);
/// non-sensitive UI prefs -> SharedPreferences.
class SecureVault {
  static const String _keyAccessToken = 'sec_access_token';
  static const String _keyRefreshToken = 'sec_refresh_token';
  static const String _keyDeviceSessionId = 'sec_device_session_id';
  static const String _keyConnectSessionId = 'sec_connect_session_id';
  static const String _keyDeviceId = 'pref_device_id';
  static const String _keySavedEmail = 'pref_saved_email';
  static const String _keyKillSwitch = 'pref_kill_switch';
  static const String _keyAutoConnect = 'pref_auto_connect';
  static const String _keyBypassLan = 'pref_bypass_lan';
  static const String _keyProtocolPref = 'pref_protocol';
  static const String _keyConnectionMode = 'pref_connection_mode';
  static const String _keyLanguage = 'pref_language';

  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    // One-time migration: move any legacy plaintext tokens into secure storage, then wipe.
    try {
      final legacyAccess = _prefs?.getString(_keyAccessToken);
      final legacyRefresh = _prefs?.getString(_keyRefreshToken);
      final legacySession = _prefs?.getString(_keyDeviceSessionId);
      if ((legacyAccess != null && legacyAccess.isNotEmpty) ||
          (legacyRefresh != null && legacyRefresh.isNotEmpty)) {
        if (legacyAccess != null && legacyAccess.isNotEmpty) {
          await _secure.write(key: _keyAccessToken, value: legacyAccess);
        }
        if (legacyRefresh != null && legacyRefresh.isNotEmpty) {
          await _secure.write(key: _keyRefreshToken, value: legacyRefresh);
        }
        if (legacySession != null && legacySession.isNotEmpty) {
          await _secure.write(key: _keyDeviceSessionId, value: legacySession);
        }
        await _prefs?.remove(_keyAccessToken);
        await _prefs?.remove(_keyRefreshToken);
        await _prefs?.remove(_keyDeviceSessionId);
      }
    } catch (_) {}
  }

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    required String deviceSessionId,
  }) async {
    await init();
    await _secure.write(key: _keyAccessToken, value: accessToken);
    await _secure.write(key: _keyRefreshToken, value: refreshToken);
    await _secure.write(key: _keyDeviceSessionId, value: deviceSessionId);
  }

  Future<String?> getAccessToken() async {
    return _secure.read(key: _keyAccessToken);
  }

  Future<String?> getRefreshToken() async {
    return _secure.read(key: _keyRefreshToken);
  }

  Future<String?> getDeviceSessionId() async {
    return _secure.read(key: _keyDeviceSessionId);
  }

  Future<String?> getConnectSessionId() => _secure.read(key: _keyConnectSessionId);

  Future<void> setConnectSessionId(String? id) async {
    if (id == null) {
      await _secure.delete(key: _keyConnectSessionId);
    } else {
      await _secure.write(key: _keyConnectSessionId, value: id);
    }
  }

  /// Stable per-install device identity, sent at login so the control plane
  /// can bind connect sessions (and max_devices accounting) to a device. Not a
  /// secret - SharedPreferences is the right store; must survive logout.
  Future<String> getOrCreateDeviceId() async {
    await init();
    final existing = _prefs?.getString(_keyDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final hex = List<int>.generate(16, (_) => random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final id = 'dev_$hex';
    await _prefs?.setString(_keyDeviceId, id);
    return id;
  }

  Future<void> clearAuthData() async {
    await _secure.delete(key: _keyAccessToken);
    await _secure.delete(key: _keyRefreshToken);
    await _secure.delete(key: _keyDeviceSessionId);
  }

  // Preferences (non-sensitive, SharedPreferences is correct here)
  Future<void> saveEmail(String email) async {
    await init();
    await _prefs?.setString(_keySavedEmail, email);
  }

  Future<String?> getSavedEmail() async {
    await init();
    return _prefs?.getString(_keySavedEmail);
  }

  Future<void> setKillSwitch(bool enabled) async {
    await init();
    await _prefs?.setBool(_keyKillSwitch, enabled);
  }

  Future<bool> getKillSwitch() async {
    await init();
    return _prefs?.getBool(_keyKillSwitch) ?? true;
  }

  Future<void> setAutoConnect(bool enabled) async {
    await init();
    await _prefs?.setBool(_keyAutoConnect, enabled);
  }

  Future<bool> getAutoConnect() async {
    await init();
    return _prefs?.getBool(_keyAutoConnect) ?? false;
  }

  Future<void> setBypassLan(bool enabled) async {
    await init();
    await _prefs?.setBool(_keyBypassLan, enabled);
  }

  Future<bool> getBypassLan() async {
    await init();
    return _prefs?.getBool(_keyBypassLan) ?? true;
  }

  Future<void> setPreferredProtocol(String protocol) async {
    await init();
    await _prefs?.setString(_keyProtocolPref, protocol);
  }

  Future<void> setConnectionMode(String mode) async {
    await init();
    await _prefs?.setString(_keyConnectionMode, mode);
  }

  Future<String> getConnectionMode() async {
    await init();
    return _prefs?.getString(_keyConnectionMode) == 'system_proxy' ? 'system_proxy' : 'tun';
  }

  Future<String> getPreferredProtocol() async {
    await init();
    return _prefs?.getString(_keyProtocolPref) ?? 'auto';
  }

  Future<void> setLanguage(String lang) async {
    await init();
    await _prefs?.setString(_keyLanguage, lang);
  }

  Future<String> getLanguage() async {
    await init();
    return _prefs?.getString(_keyLanguage) ?? 'zh';
  }
}
