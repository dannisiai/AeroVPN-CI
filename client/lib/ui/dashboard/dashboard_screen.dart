import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../config/app_theme.dart';
import '../../core/vpn/vpn_status.dart';
import '../../state/account_provider.dart';
import '../../state/locale_provider.dart';
import '../../state/region_provider.dart';
import '../../state/vpn_provider.dart';
import '../faq/faq_screen.dart';
import '../regions/region_picker_sheet.dart';
import 'connect_button.dart';
import 'server_card.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  void _showRegionPicker(BuildContext context) {
    final regionProv = context.read<RegionProvider>();
    final vpnProv = context.read<VpnProvider>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RegionPickerSheet(
        regions: regionProv.regions,
        currentRegion: regionProv.selectedRegion,
        currentCity: regionProv.selectedCity,
        onSelectLocation: (region, city) {
          regionProv.selectLocation(region, city);
          vpnProv.connect(region: region, city: city);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vpn = context.watch<VpnProvider>();
    final regionProv = context.watch<RegionProvider>();
    final accountProv = context.watch<AccountProvider>();
    final locale = context.watch<LocaleProvider>();

    final plan = accountProv.plan;

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await Future.wait([
              regionProv.fetchRegions(),
              accountProv.fetchAccount(),
            ]);
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Top Bar: FAQ (?) icon on top-right matching video
                          const Align(
                            alignment: Alignment.topRight,
                            child: _FaqButtonWithTooltip(),
                          ),

                          // Vertical Area: Connect Button placed at the user's marked position
                          Expanded(
                            child: Align(
                              alignment: const Alignment(0, 0.05),
                              child: ConnectButton(
                                status: vpn.status,
                                onTap: () {
                                  // A missing/offline/expired plan must never
                                  // prevent stopping an existing native tunnel.
                                  if (vpn.isConnected || vpn.isConnecting || vpn.status == VpnStatus.disconnecting) {
                                    vpn.toggleConnect();
                                    return;
                                  }
                                  if (plan == null || !plan.isActive) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('您尚未开通会员套餐或套餐已到期，请先购买订阅！'),
                                        backgroundColor: Color(0xFFDC2626),
                                      ),
                                    );
                                    return;
                                  }
                                  vpn.toggleConnect(
                                    region: regionProv.selectedRegion,
                                    city: regionProv.selectedCity,
                                  );
                                },
                              ),
                            ),
                          ),

                          const SizedBox(height: 24),

                          // Bottom Section: Full-width Cards stretching across the screen
                          // 1. Selected Server Card (Full Width)
                          SizedBox(
                            width: double.infinity,
                            child: ServerCard(
                              region: regionProv.selectedRegion,
                              city: regionProv.selectedCity,
                              stats: vpn.stats,
                              onChangeLocation: () => _showRegionPicker(context),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // 2. 3-Column Plan & Status Card (套餐等级 | 剩余天数 | 剩余流量)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
                            decoration: BoxDecoration(
                              color: AppTheme.card,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: AppTheme.cardBorder, width: 1.2),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                // Col 1: 套餐等级
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFE0F2FE),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: const Center(
                                          child: Icon(Icons.cloud_outlined, color: Color(0xFF0284C7), size: 24),
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        (plan != null && plan.name.isNotEmpty && plan.name != 'Pro Unlimited')
                                            ? plan.name
                                            : '未开通会员',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                          color: AppTheme.textPrimary,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        locale.t('plan_tier'),
                                        style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(width: 1, height: 48, color: AppTheme.cardBorder),

                                // Col 2: 剩余天数 / 到期状态
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFFEE2E2),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: const Center(
                                          child: Icon(Icons.access_time_rounded, color: Color(0xFFEF4444), size: 24),
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        '${(plan != null && plan.isActive) ? plan.remainingDays : 0} 天',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                          color: AppTheme.textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        (plan != null && plan.isActive) ? locale.t('days_remaining') : locale.t('expired'),
                                        style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(width: 1, height: 48, color: AppTheme.cardBorder),

                                // Col 3: 剩余流量
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF1F5F9),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: const Center(
                                          child: Icon(Icons.sync_rounded, color: Color(0xFF64748B), size: 24),
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        '${(plan != null && plan.isActive) ? plan.trafficGb.toStringAsFixed(1) : "0.0"} GB',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                          color: AppTheme.textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        locale.t('remaining_traffic'),
                                        style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),

                          if (vpn.errorMessage != null) ...[
                            const SizedBox(height: 14),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFEF2F2),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFFFCA5A5)),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.error_outline_rounded, color: Color(0xFFDC2626), size: 18),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      vpn.errorMessage!,
                                      style: const TextStyle(color: Color(0xFFDC2626), fontSize: 13),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 10),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _FaqButtonWithTooltip extends StatefulWidget {
  const _FaqButtonWithTooltip();

  @override
  State<_FaqButtonWithTooltip> createState() => _FaqButtonWithTooltipState();
}

class _FaqButtonWithTooltipState extends State<_FaqButtonWithTooltip> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleProvider>();

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topRight,
        children: [
          // Question Mark Button
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              hoverColor: const Color(0xFFEAEEF4),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const FaqScreen()),
                );
              },
              child: const Padding(
                padding: EdgeInsets.all(8.0),
                child: Icon(
                  Icons.help_outline_rounded,
                  color: Colors.black,
                  size: 24,
                ),
              ),
            ),
          ),

          // Tooltip Bubble: positioned below the button and shifted to the left (not centered!)
          if (_isHovered)
            Positioned(
              top: 40,
              right: 2,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF52565B),
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    locale.t('faq_title'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
