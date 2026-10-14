import 'package:flutter/material.dart';
import '../../config/app_theme.dart';
import '../../core/api/api_models.dart';
import '../../core/vpn/vpn_status.dart';

class ServerCard extends StatelessWidget {
  final RegionModel? region;
  final CityModel? city;
  final VpnStats stats;
  final VoidCallback onChangeLocation;

  const ServerCard({
    super.key,
    required this.region,
    required this.city,
    required this.stats,
    required this.onChangeLocation,
  });

  @override
  Widget build(BuildContext context) {
    final flag = region?.flagEmoji ?? '🌐';
    final countryName = region?.name ?? 'United States';
    final cityName = city?.name ?? 'New York';
    final latency = city?.latencyMs ?? 35;

    return InkWell(
      onTap: onChangeLocation,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.cardBorder, width: 1),
        ),
        child: Row(
          children: [
            // Flag avatar
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: Center(
                child: Text(flag, style: const TextStyle(fontSize: 26)),
              ),
            ),
            const SizedBox(width: 16),
            // Location Details
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        cityName,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        countryName,
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      // Latency badge
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: latency < 60
                              ? AppTheme.statusConnected
                              : (latency < 120 ? AppTheme.statusConnecting : AppTheme.statusDisconnected),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '$latency ms',
                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
