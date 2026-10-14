import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'vpn_service.dart';
import 'vpn_status.dart';

/// Native Platform VPN Service Implementation
/// Bridges Flutter client directly to native OS VPN subsystems:
/// - Android: android.net.VpnService (via MainActivity.kt & AeroVpnService.kt)
/// - iOS/macOS: NetworkExtension NEPacketTunnelProvider & NETunnelProviderManager
class MethodChannelVpnService implements VpnService {
  @override
  Future<void> cancelPendingStart() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _channel.invokeMethod<void>('cancelPendingStart');
    }
  }

  static const MethodChannel _channel = MethodChannel('com.aerovpn.client/vpn');

  String _assignedIp = '';
  String _country = '';
  String _city = '';
  bool _killSwitch = true;
  DateTime? _connectedSince;

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
    _killSwitch = killSwitch;

    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('startTunnel', {
        'config_json': configJson,
        'assigned_ip': assignedIp,
        'country': country,
        'city': city,
        'kill_switch': killSwitch,
        'clash_secret': clashSecret,
      });

      // The native side reports its true state. Android replies "connecting"
      // (the tunnel service starts asynchronously and the periodic getStats
      // poll resolves the final state); iOS reports NetworkExtension state,
      // macOS awaits process startup. Any other status is a failure.
      final status = res?['status'] as String? ?? 'connecting';
      if (status == 'connected') {
        _connectedSince = DateTime.now();
      } else if (status == 'connecting' || status == 'reconnecting') {
        _connectedSince = null;
      } else {
        _connectedSince = null;
        throw Exception('Native VPN start failed with status: $status');
      }
    } on PlatformException catch (e) {
      _connectedSince = null;
      throw Exception('Failed to start native VPN tunnel: ${e.message} (${e.code})');
    } catch (e) {
      _connectedSince = null;
      throw Exception('Native VPN start failure: $e');
    }
  }

  @override
  Future<void> stopTunnel() async {
    await _channel.invokeMethod('stopTunnel');
    _connectedSince = null;
  }

  /// Removes the native VPN profile, purging the node credentials the OS keeps
  /// in the tunnel provider configuration (so they never outlive logout).
  ///
  /// Cross-platform method-channel contract: the method name is exactly
  /// `removeVpnProfile` (implemented by the iOS AppDelegate; the macOS host
  /// must match this exact name).
  ///
  /// Best-effort by design: on platforms without a handler for this method
  /// (Android MainActivity, the Windows daemon path) the invoke fails with
  /// MissingPluginException / PlatformException and is swallowed here, making
  /// this a silent no-op there.
  Future<void> removeVpnProfile() async {
    try {
      await _channel.invokeMethod<void>('removeVpnProfile');
    } on MissingPluginException {
      // No native handler for this method on this platform: nothing to remove.
    } on PlatformException {
      // Profile cleanup is best-effort; the caller (logout) must never fail.
    }
  }

  @override
  Future<void> setKillSwitch(bool enabled) async {
    final previous = _killSwitch;
    try {
      final response = await _channel.invokeMethod<dynamic>(
        'setKillSwitch',
        {'enabled': enabled},
      );
      if (response is Map && response['supported'] == false) {
        throw PlatformException(
          code: 'KILL_SWITCH_UNSUPPORTED',
          message: 'This platform does not support the requested kill switch.',
        );
      }
      _killSwitch = enabled;
    } catch (_) {
      _killSwitch = previous;
      rethrow;
    }
  }

  @override
  Future<VpnStats> getStats() async {
    final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('getStats')
        .timeout(const Duration(seconds: 5));
    if (res != null) {
      final statusStr = res['status'] as String?;
      final status = VpnStatus.values.firstWhere(
        (value) => value.name == statusStr,
        orElse: () => throw StateError('Unknown native VPN status: $statusStr'),
      );
      if (status == VpnStatus.connected) {
        _connectedSince ??= DateTime.now();
      } else if (status == VpnStatus.disconnected || status == VpnStatus.error) {
        _connectedSince = null;
      }

      final uptime = _connectedSince != null ? DateTime.now().difference(_connectedSince!).inSeconds : 0;

      return VpnStats(
        status: status,
        assignedIp: res['assigned_ip'] as String? ?? _assignedIp,
        country: res['country'] as String? ?? _country,
        city: res['city'] as String? ?? _city,
        uptimeSec: (res['uptime_sec'] as num?)?.toInt() ?? uptime,
        killSwitch: res['kill_switch'] as bool? ?? _killSwitch,
        downlinkBps: (res['downlink_bps'] as num?)?.toInt() ?? 0,
        uplinkBps: (res['uplink_bps'] as num?)?.toInt() ?? 0,
        totalDownBytes: (res['total_down_bytes'] as num?)?.toInt() ?? 0,
        totalUpBytes: (res['total_up_bytes'] as num?)?.toInt() ?? 0,
        lastError: res['last_error'] as String?,
      );
    }
    throw StateError('Native VPN returned no status');
  }

  @override
  void dispose() {}
}
