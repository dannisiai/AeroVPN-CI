enum VpnStatus {
  disconnected,
  connecting,
  connected,
  reconnecting,
  disconnecting,
  error,
}

class VpnStats {
  final VpnStatus status;
  final String? lastError;
  final String assignedIp;
  final String country;
  final String city;
  final int uptimeSec;
  final bool killSwitch;
  final int downlinkBps;
  final int uplinkBps;
  final int totalDownBytes;
  final int totalUpBytes;

  VpnStats({
    required this.status,
    this.lastError,
    this.assignedIp = '',
    this.country = '',
    this.city = '',
    this.uptimeSec = 0,
    this.killSwitch = true,
    this.downlinkBps = 0,
    this.uplinkBps = 0,
    this.totalDownBytes = 0,
    this.totalUpBytes = 0,
  });

  String get downloadSpeedFormatted => _formatBitrate(downlinkBps);
  String get uploadSpeedFormatted => _formatBitrate(uplinkBps);
  String get totalTransferFormatted => _formatBytes(totalDownBytes + totalUpBytes);

  String get uptimeFormatted {
    final hours = uptimeSec ~/ 3600;
    final minutes = (uptimeSec % 3600) ~/ 60;
    final seconds = uptimeSec % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  static String _formatBitrate(int bytesPerSec) {
    final bitsPerSec = bytesPerSec * 8;
    if (bitsPerSec >= 1000 * 1000 * 1000) {
      return '${(bitsPerSec / (1000 * 1000 * 1000)).toStringAsFixed(1)} Gbps';
    } else if (bitsPerSec >= 1000 * 1000) {
      return '${(bitsPerSec / (1000 * 1000)).toStringAsFixed(1)} Mbps';
    } else if (bitsPerSec >= 1000) {
      return '${(bitsPerSec / 1000).toStringAsFixed(0)} Kbps';
    }
    return '$bitsPerSec bps';
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    } else if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }
}
