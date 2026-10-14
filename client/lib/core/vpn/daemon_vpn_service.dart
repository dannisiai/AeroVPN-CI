import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../../config/brand_config.dart';
import 'vpn_service.dart';
import 'vpn_status.dart';

/// Desktop Windows / Linux Daemon VPN Service
/// Communicates with the local privileged helper service (vpn-daemon.exe) over localhost IPC
class DaemonVpnService implements VpnService {
  @override
  Future<void> cancelPendingStart() async {}

  final String daemonUrl;
  final http.Client _client = http.Client();
  static const MethodChannel _systemProxy = MethodChannel('aerovpn/system_proxy');
  static const MethodChannel _daemonControl = MethodChannel('aerovpn/daemon_control');
  int _appliedProxyPort = 0;

  String _assignedIp = '';
  String _country = '';
  String _city = '';
  String? _cachedToken;
  Future<void>? _daemonStartRequest;

  DaemonVpnService({this.daemonUrl = BrandConfig.daemonIpcUrl});

  Future<void> _ensureWindowsDaemonStarted() async {
    if (!Platform.isWindows) return;
    final pending = _daemonStartRequest;
    if (pending != null) {
      await pending;
      return;
    }

    final request = _daemonControl
        .invokeMethod<void>('startIfStopped')
        .then<void>((_) {});
    _daemonStartRequest = request;
    try {
      await request;
    } catch (_) {
      if (identical(_daemonStartRequest, request)) {
        _daemonStartRequest = null;
      }
      rethrow;
    }
  }

  Future<http.Response> _requestStatsWithStartupRetry(
    Map<String, String> headers,
  ) async {
    final attempts = Platform.isWindows ? 12 : 1;
    Object? lastFailure;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        return await _client
            .get(Uri.parse('$daemonUrl/tunnel/stats'), headers: headers)
            .timeout(const Duration(seconds: 2));
      } catch (error) {
        if (error is! SocketException &&
            error is! TimeoutException &&
            error is! http.ClientException) {
          rethrow;
        }
        lastFailure = error;
        if (attempt + 1 < attempts) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    }
    _daemonStartRequest = null;
    throw lastFailure ?? StateError('AeroVPN daemon did not become available');
  }

  Future<String?> _getIpcToken() async {
    if (kIsWeb) return null;
    if (_cachedToken != null) return _cachedToken;

    try {
      final envToken = Platform.environment['AEROVPN_IPC_TOKEN'];
      if (envToken != null && envToken.isNotEmpty) {
        _cachedToken = envToken;
        return _cachedToken;
      }

      // The elevated installer provisions one credential in the installing user's
      // profile. Do not fall back to the old shared ProgramData token: other local
      // users could read it and use it to control the SYSTEM service.
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        final p = File('$localAppData\\AeroVPN\\ipc.token');
        if (await p.exists()) {
          final t = (await p.readAsString()).trim();
          if (t.isNotEmpty) {
            _cachedToken = t;
            return _cachedToken;
          }
        }
      }

    } catch (_) {}

    return null;
  }

  Future<Map<String, String>> _buildHeaders() async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'X-AeroVPN-Client': '1',
    };
    final token = await _getIpcToken();
    if (token != null && token.isNotEmpty) {
      headers['X-AeroVPN-Token'] = token;
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  @override
  Future<void> startTunnel({
    required String configJson,
    required String assignedIp,
    required String country,
    required String city,
    required bool killSwitch,
    String clashSecret = '',
  }) async {
    _assignedIp = assignedIp;
    _country = country;
    _city = city;

    try {
      await _ensureWindowsDaemonStarted();
      final headers = await _buildHeaders();
      final res = await _client.post(
        Uri.parse('$daemonUrl/tunnel/start'),
        headers: headers,
        body: jsonEncode({
          'config_json': configJson,
          'assigned_ip': assignedIp,
          'country': country,
          'city': city,
          'clash_secret': clashSecret,
        }),
      ).timeout(const Duration(seconds: 60));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final statusStr = data['status'] as String?;
        if (statusStr != 'connected' && statusStr != 'connecting' && statusStr != 'reconnecting') {
          throw StateError('Daemon VPN start failed with status: $statusStr');
        }
        return;
      } else {
        Map<String, dynamic>? errBody;
        try {
          errBody = jsonDecode(res.body) as Map<String, dynamic>;
        } catch (_) {}
        final errMsg = errBody?['error'] ?? 'Daemon returned HTTP ${res.statusCode}';
        throw Exception(errMsg);
      }
    } catch (e) {
      throw Exception('Failed to connect to VPN daemon at $daemonUrl: $e');
    }
  }

  @override
  Future<void> stopTunnel() async {
    await _ensureWindowsDaemonStarted();
    final headers = await _buildHeaders();
    final response = await _client.post(
      Uri.parse('$daemonUrl/tunnel/stop'),
      headers: headers,
    ).timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw HttpException('VPN stop failed: HTTP ${response.statusCode}: ${response.body}');
    }
    if (Platform.isWindows) {
      await _systemProxy.invokeMethod<void>('disable');
      _appliedProxyPort = 0;
    }
  }

  @override
  Future<void> setKillSwitch(bool enabled) async {
    // Required by the shared mobile/Apple interface; Windows has no such feature.
    throw UnsupportedError('Kill Switch is not available on Windows');
  }

  @override
  Future<VpnStats> getStats() async {
    http.Response res;
    try {
      await _ensureWindowsDaemonStarted();
      final headers = await _buildHeaders();
      res = await _requestStatsWithStartupRetry(headers);
    } catch (_) {
      _daemonStartRequest = null;
      // Keep a previously applied proxy while daemon state is unknown. Restoring
      // the old system settings here could silently bypass a still-running core.
      rethrow;
    }
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final statusStr = data['status'] as String?;
      final status = VpnStatus.values.firstWhere(
        (value) => value.name == statusStr,
        orElse: () => throw StateError('Unknown daemon VPN status: $statusStr'),
      );

      final lastError = data['last_error'] as String?;

      if (Platform.isWindows) {
        final port = (data['proxy_port'] as num?)?.toInt() ?? 0;
        if (status == VpnStatus.connected && port > 0) {
          if (_appliedProxyPort != port) {
            try {
              await _systemProxy.invokeMethod<void>('enable', {'port': port});
              _appliedProxyPort = port;
            } catch (error) {
              await stopTunnel();
              rethrow;
            }
          }
        } else if (_appliedProxyPort != 0 || status == VpnStatus.disconnected || status == VpnStatus.error) {
          await _systemProxy.invokeMethod<void>('disable');
          _appliedProxyPort = 0;
        }
      }

      return VpnStats(
        status: status,
        assignedIp: data['assigned_ip'] as String? ?? _assignedIp,
        country: data['country'] as String? ?? _country,
        city: data['city'] as String? ?? _city,
        uptimeSec: (data['uptime_sec'] as num?)?.toInt() ?? 0,
        killSwitch: false,
        downlinkBps: (data['downlink_bps'] as num?)?.toInt() ?? 0,
        uplinkBps: (data['uplink_bps'] as num?)?.toInt() ?? 0,
        totalDownBytes: (data['total_down_bytes'] as num?)?.toInt() ?? 0,
        totalUpBytes: (data['total_up_bytes'] as num?)?.toInt() ?? 0,
        lastError: lastError,
      );
    }
    // A non-200 response does not prove that the tunnel has stopped, so preserve
    // the current proxy until a successful stats response confirms disconnect.
    throw HttpException('Cannot read VPN state: HTTP ${res.statusCode}');
  }

  @override
  void dispose() {
    _client.close();
  }
}
