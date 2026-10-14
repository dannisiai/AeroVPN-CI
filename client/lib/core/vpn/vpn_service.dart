import 'vpn_status.dart';

abstract class VpnService {
  Future<void> startTunnel({
    required String configJson,
    required String assignedIp,
    required String country,
    required String city,
    required bool killSwitch,
    String clashSecret = '',
  });

  Future<void> stopTunnel();

  Future<void> cancelPendingStart();

  Future<void> setKillSwitch(bool enabled);

  Future<VpnStats> getStats();

  void dispose();
}
