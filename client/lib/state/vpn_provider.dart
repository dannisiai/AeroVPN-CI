import 'dart:async';
import 'package:flutter/foundation.dart';
import '../core/api/api_client.dart';
import '../core/api/api_models.dart';
import '../core/engine/singbox_config_builder.dart';
import '../core/security/secure_vault.dart';
import '../core/vpn/vpn_service.dart';
import '../core/vpn/vpn_status.dart';

class VpnProvider extends ChangeNotifier {
  final ApiClient _apiClient;
  final VpnService _vpnService;
  final SecureVault _vault;
  VpnStats _stats = VpnStats(status: VpnStatus.disconnected);
  Timer? _statsTimer;
  Future<void> _operations = Future<void>.value();
  int _generation = 0;
  int _queuedOperations = 0;
  Future<void>? _statusRefresh;
  bool _disposed = false;
  bool _statusReadFailed = false;
  bool _killSwitch = defaultTargetPlatform != TargetPlatform.windows;
  bool _autoConnect = false;
  bool _bypassLan = true;
  String _preferredProtocol = 'auto';
  String _connectionMode = 'tun';
  ConnectResponse? _currentSession;
  String? _sessionId;
  String? _errorMessage;

  VpnProvider(this._apiClient, this._vpnService, this._vault);
  VpnStats get stats => _stats;
  VpnStatus get status => _stats.status;
  bool get isConnected => status == VpnStatus.connected;
  bool get isConnecting => status == VpnStatus.connecting || status == VpnStatus.reconnecting;
  bool get isDisconnected => status == VpnStatus.disconnected;
  bool get isBusy => _queuedOperations != 0;
  bool get supportsKillSwitch => defaultTargetPlatform != TargetPlatform.windows;
  bool get killSwitch => _killSwitch;
  bool get autoConnect => _autoConnect;
  bool get bypassLan => _bypassLan;
  String get preferredProtocol => _preferredProtocol;
  bool get supportsSystemProxy => !kIsWeb && const {
        TargetPlatform.windows,
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      }.contains(defaultTargetPlatform);
  String get connectionMode => _connectionMode;
  String? get errorMessage {
    final message = _errorMessage ?? _stats.lastError;
    return message == null || message.isEmpty ? null : message;
  }
  ConnectResponse? get currentSession => _currentSession;

  Future<void> initPreferences() async {
    _killSwitch = supportsKillSwitch ? await _vault.getKillSwitch() : false;
    _autoConnect = await _vault.getAutoConnect();
    _bypassLan = await _vault.getBypassLan();
    _preferredProtocol = await _vault.getPreferredProtocol();
    _connectionMode = supportsSystemProxy ? await _vault.getConnectionMode() : 'tun';
    _sessionId = await _vault.getConnectSessionId();
    // Attach to the actual native service, independently of login/auto-connect.
    await refreshStatus();
    _statsTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(refreshStatus());
    });
    _notify();
  }

  Future<void> refreshStatus() {
    if (_disposed || isBusy) return Future<void>.value();
    return _statusRefresh ??= _readStatus().whenComplete(() {
      _statusRefresh = null;
    });
  }

  Future<void> _readStatus() async {
    final generation = _generation;
    try {
      final latest = await _vpnService.getStats();
      if (_isCurrent(generation) && !isBusy) {
        _stats = latest;
        if (_statusReadFailed) _errorMessage = null;
        _statusReadFailed = false;
        _notify();
      }
    } catch (error) {
      if (_isCurrent(generation) && !isBusy) {
        _errorMessage = '无法确认 VPN 状态：$error';
        _statusReadFailed = true;
        _stats = _withError(_stats, _errorMessage!, unknown: true);
        _notify();
      }
    }
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _queuedOperations++;
    final result = _operations.then((_) async {
      try {
        await action();
      } finally {
        _queuedOperations--;
        _notify();
      }
    });
    // A rejected operation must not poison subsequent stop/retry operations.
    _operations = result.catchError((Object _) {});
    return result;
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  Future<void> toggleConnect({RegionModel? region, CityModel? city}) async {
    if (isConnected || isConnecting || status == VpnStatus.disconnecting) {
      try {
        await disconnect();
      } catch (_) {
        // disconnect already records the native failure for the UI.
      }
    } else {
      await connect(region: region, city: city);
    }
  }

  Future<void> connect({RegionModel? region, CityModel? city}) {
    final generation = ++_generation;
    _errorMessage = null;
    _cancelPendingStart();
    _stats = VpnStats(
      status: VpnStatus.connecting,
      country: region?.name ?? _stats.country,
      city: city?.name ?? _stats.city,
      killSwitch: _killSwitch,
    );
    _notify();
    return _enqueue(() async {
      if (!_isCurrent(generation)) return;
      ConnectResponse? fetched;
      var nativeStartRequested = false;
      try {
        // A location selection is a switch; Windows start rejects a live core.
        await _stopAndRevoke();
        if (!_isCurrent(generation)) return;
        fetched = await _apiClient.connect(
          regionId: region?.id ?? 'us',
          cityId: city?.id,
          protocolPreference: _preferredProtocol,
        );
        if (!_isCurrent(generation)) {
          await _revoke(fetched.sessionId);
          return;
        }
        final clashSecret = SingboxConfigBuilder.generateClashSecret();
        final clashPort = await SingboxConfigBuilder.findAvailablePort();
        final systemProxy = supportsSystemProxy && _connectionMode == 'system_proxy';
        final systemProxyWithTun = systemProxy && const {
          TargetPlatform.android,
          TargetPlatform.iOS,
        }.contains(defaultTargetPlatform);
        var systemProxyPort = 2080;
        if (systemProxy) {
          do {
            systemProxyPort = await SingboxConfigBuilder.findAvailablePort(defaultPort: clashPort == 2080 ? 2081 : 2080);
          } while (systemProxyPort == clashPort);
        }
        if (!_isCurrent(generation)) {
          await _revoke(fetched.sessionId);
          return;
        }
        final configJson = SingboxConfigBuilder.buildConfig(
          connectData: fetched,
          bypassLocalLan: _bypassLan,
          // Windows strict routing is a TUN/DNS setting, independent of the
          // removed firewall Kill Switch.
          strictRoute: defaultTargetPlatform == TargetPlatform.windows || _killSwitch,
          useGVisorStack: defaultTargetPlatform == TargetPlatform.iOS && _killSwitch,
          clashSecret: clashSecret,
          clashPort: clashPort,
          systemProxy: systemProxy,
          systemProxyPort: systemProxyPort,
          systemProxyWithTun: systemProxyWithTun,
        );
        _currentSession = fetched;
        _sessionId = fetched.sessionId;
        await _vault.setConnectSessionId(_sessionId);
        if (!_isCurrent(generation)) {
          await _stopAndRevoke();
          return;
        }
        // An IPC timeout can leave a live native tunnel, so mark before await.
        nativeStartRequested = true;
        await _vpnService.startTunnel(
          configJson: configJson,
          assignedIp: fetched.virtualIp,
          country: fetched.countryName,
          city: fetched.cityName,
          killSwitch: _killSwitch,
          clashSecret: clashSecret,
        );
        if (!_isCurrent(generation)) {
          await _stopAndRevoke();
          return;
        }
        final latest = await _vpnService.getStats();
        if (_isCurrent(generation)) {
          _stats = latest;
          _notify();
        }
      } catch (error) {
        Object failure = error;
        if (nativeStartRequested) {
          try {
            await _stopAndRevoke();
          } catch (stopError) {
            failure = '$error；停止未完成：$stopError';
          }
        } else if (fetched != null) {
          await _revoke(fetched.sessionId);
          if (_sessionId == fetched.sessionId) {
            _sessionId = null;
            _currentSession = null;
            await _vault.setConnectSessionId(null);
          }
        }
        if (_isCurrent(generation)) await _recordFailure(failure, generation);
      }
    });
  }

  Future<void> disconnect() {
    // Invalidate pending results before waiting for the lifecycle queue.
    final generation = ++_generation;
    _errorMessage = null;
    _cancelPendingStart();
    _stats = VpnStats(status: VpnStatus.disconnecting, killSwitch: _killSwitch);
    _notify();
    return _enqueue(() async {
      if (!_isCurrent(generation)) return;
      try {
        await _stopAndRevoke();
        if (_isCurrent(generation)) {
          _stats = VpnStats(status: VpnStatus.disconnected, killSwitch: _killSwitch);
          _notify();
        }
      } catch (error) {
        if (_isCurrent(generation)) await _recordFailure(error, generation);
        rethrow;
      }
    });
  }

  Future<void> _stopAndRevoke() async {
    await _vpnService.stopTunnel();
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (true) {
      final latest = await _vpnService.getStats();
      if (latest.status == VpnStatus.disconnected) break;
      if (latest.status == VpnStatus.error) {
        throw StateError(latest.lastError ?? 'VPN 停止失败');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('VPN 停止尚未确认：${latest.status.name}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final oldSessionId = _sessionId;
    _currentSession = null;
    _sessionId = null;
    await _vault.setConnectSessionId(null);
    if (oldSessionId != null) await _revoke(oldSessionId);
  }

  void _cancelPendingStart() {
    // Android consent can otherwise keep the serialized queue waiting forever.
    // Native stop still runs through the queue and must be confirmed separately.
    unawaited(_vpnService.cancelPendingStart().catchError((Object _) {}));
  }

  Future<void> _revoke(String sessionId) async {
    if (sessionId.isEmpty) return;
    try {
      await _apiClient.revokeConnectSession(sessionId).timeout(const Duration(seconds: 3));
    } catch (_) {
      // Native stop is confirmed; offline server bookkeeping is best effort.
    }
  }

  Future<void> _recordFailure(Object error, int generation) async {
    VpnStats observed;
    try {
      observed = _withError(await _vpnService.getStats(), error.toString());
    } catch (_) {
      observed = _withError(_stats, error.toString(), unknown: true);
    }
    if (!_isCurrent(generation)) return;
    _errorMessage = error.toString();
    _stats = observed;
    _notify();
  }

  VpnStats _withError(VpnStats previous, String error, {bool unknown = false}) => VpnStats(
    status: unknown ? VpnStatus.error : previous.status,
    lastError: error,
    assignedIp: previous.assignedIp,
    country: previous.country,
    city: previous.city,
    uptimeSec: previous.uptimeSec,
    killSwitch: previous.killSwitch,
    downlinkBps: previous.downlinkBps,
    uplinkBps: previous.uplinkBps,
    totalDownBytes: previous.totalDownBytes,
    totalUpBytes: previous.totalUpBytes,
  );

  Future<void> setKillSwitch(bool enabled) => _enqueue(() async {
    if (!supportsKillSwitch) {
      throw UnsupportedError('Kill Switch is not available on Windows');
    }
    if (enabled == _killSwitch) return;
    final previous = _killSwitch;
    final latest = await _vpnService.getStats();
    final active = latest.status == VpnStatus.connected ||
        latest.status == VpnStatus.connecting || latest.status == VpnStatus.reconnecting;
    // Inactive mobile/Apple preferences are applied with the next start.
    // Saving an iOS on-demand rule while idle could start stale credentials.
    final updateNative = active;
    if (updateNative) {
      await _vpnService.setKillSwitch(enabled);
    }
    try {
      await _vault.setKillSwitch(enabled);
      _killSwitch = enabled;
    } catch (_) {
      if (updateNative) {
        await _vpnService.setKillSwitch(previous);
      }
      rethrow;
    }
    _notify();
  });

  Future<void> setAutoConnect(bool enabled) async {
    await _vault.setAutoConnect(enabled);
    _autoConnect = enabled;
    _notify();
  }

  Future<void> setBypassLan(bool enabled) async {
    await _vault.setBypassLan(enabled);
    _bypassLan = enabled;
    _notify();
  }

  Future<void> setPreferredProtocol(String protocol) async {
    await _vault.setPreferredProtocol(protocol);
    _preferredProtocol = protocol;
    _notify();
  }

  Future<void> setConnectionMode(String mode) => _enqueue(() async {
    if (!supportsSystemProxy || (mode != 'tun' && mode != 'system_proxy')) {
      throw ArgumentError('Unsupported connection mode');
    }
    final latest = await _vpnService.getStats();
    if (latest.status != VpnStatus.disconnected) {
      throw StateError('请先断开连接，再切换连接方式');
    }
    await _vault.setConnectionMode(mode);
    _connectionMode = mode;
    _notify();
  });

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _statsTimer?.cancel();
    _vpnService.dispose();
    super.dispose();
  }
}
