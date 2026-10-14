import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../config/brand_config.dart';
import 'daemon_vpn_service.dart';
import 'method_channel_vpn_service.dart';
import 'vpn_service.dart';

/// Platform-Aware VPN Service Factory
/// Instantiates the optimal native tunnel service according to host OS:
/// - Windows / Linux: Talks to the local privileged helper daemon via HTTP IPC
/// - Android / iOS / macOS: Talks to native VpnService / NetworkExtension via MethodChannel
class PlatformVpnService {
  static VpnService create({String daemonUrl = BrandConfig.daemonIpcUrl}) {
    if (kIsWeb) {
      return DaemonVpnService(daemonUrl: daemonUrl);
    }

    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      return MethodChannelVpnService();
    }

    return DaemonVpnService(daemonUrl: daemonUrl);
  }
}
