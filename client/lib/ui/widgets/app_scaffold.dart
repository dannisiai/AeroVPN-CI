import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../config/app_theme.dart';
import '../../config/avatar_asset.dart';
import '../../config/brand_config.dart';
import '../../state/account_provider.dart';
import '../../state/auth_provider.dart';
import '../../state/locale_provider.dart';
import '../account/account_screen.dart';
import '../dashboard/dashboard_screen.dart';
import '../more/more_screen.dart';
import '../settings/settings_screen.dart';

class AppScaffold extends StatefulWidget {
  const AppScaffold({super.key});

  @override
  State<AppScaffold> createState() => _AppScaffoldState();
}

class _AppScaffoldState extends State<AppScaffold> {
  int _currentIndex = 0;

  final List<Widget> _pages = const [
    DashboardScreen(),
    AccountScreen(),
    MoreScreen(),
    SettingsScreen(),
  ];

  void _showInviteDialog(BuildContext context) {
    final locale = context.read<LocaleProvider>();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.card_giftcard_rounded, color: Color(0xFFFF9800)),
            const SizedBox(width: 10),
            Text(
              locale.t('nav_referral'),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFFD8A8)),
              ),
              child: const Text(
                '每成功邀请 1 位好友注册使用，双方立得 3 天 VIP 订阅及 10GB 高速流量！',
                style: TextStyle(color: Color(0xFFEA580C), fontSize: 13, height: 1.4),
              ),
            ),
            const SizedBox(height: 18),
            const Text('我的专属邀请码', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('NANO-88992', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, letterSpacing: 1.5)),
                  InkWell(
                    onTap: () {
                      Clipboard.setData(const ClipboardData(text: 'NANO-88992'));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('邀请码已复制到剪贴板！')),
                      );
                    },
                    child: const Icon(Icons.copy_rounded, size: 18, color: AppTheme.primary),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(locale.t('cancel'), style: const TextStyle(color: AppTheme.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              Clipboard.setData(const ClipboardData(text: 'https://aerovpn.com/r/88992'));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('专属推广链接已复制！')),
              );
            },
            child: const Text('复制专属链接'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleProvider>();
    final auth = context.watch<AuthProvider>();
    final account = context.watch<AccountProvider>();
    final isDesktop = MediaQuery.of(context).size.width >= 720;

    final userEmail = auth.user?.email ?? '2171300946@qq.com';
    final plan = account.plan;
    final planBadgeText = (plan != null && plan.isActive) ? plan.name : 'VIP 会员';

    if (isDesktop) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        body: Row(
          children: [
            // Left Navigation Rail for Windows Desktop / macOS
            Container(
              width: 250,
              decoration: const BoxDecoration(
                color: AppTheme.surface,
                border: Border(right: BorderSide(color: AppTheme.cardBorder, width: 1)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 24),

                  // Brand Header (Shield Icon + AeroVPN)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: AppTheme.surface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppTheme.cardBorder, width: 1.2),
                          ),
                          child: Center(
                            child: Image.asset(
                              'assets/app_logo.png',
                              width: 22,
                              height: 22,
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Text(
                          BrandConfig.appName,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),

                  // User Profile Section (Layout inspired by Image 1: Avatar + Email + Tag)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppTheme.card,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppTheme.cardBorder),
                      ),
                      child: Row(
                        children: [
                          ClipOval(
                            child: Image.memory(
                              kDefaultAvatarBytes,
                              width: 44,
                              height: 44,
                              fit: BoxFit.cover,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  userEmail,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.textPrimary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFF7ED),
                                    borderRadius: BorderRadius.circular(5),
                                    border: Border.all(color: const Color(0xFFFFD8A8), width: 0.8),
                                  ),
                                  child: Text(
                                    planBadgeText,
                                    style: const TextStyle(
                                      color: Color(0xFFFF9800),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Nav Items (Expanded from Image 1: 首页, 商城, 邀请赚钱, 每日签到, 更多, 设置)
                  _buildDesktopNavItem(
                    index: 0,
                    icon: Icons.home_outlined,
                    label: locale.t('nav_home'),
                    onTap: () => setState(() => _currentIndex = 0),
                  ),
                  _buildDesktopNavItem(
                    index: 1,
                    icon: Icons.shopping_bag_outlined,
                    label: locale.t('nav_store'),
                    onTap: () => setState(() => _currentIndex = 1),
                  ),
                  _buildDesktopActionItem(
                    icon: Icons.card_giftcard_outlined,
                    label: locale.t('nav_referral'),
                    onTap: () => _showInviteDialog(context),
                  ),

                  _buildDesktopNavItem(
                    index: 2,
                    icon: Icons.more_horiz_rounded,
                    label: locale.t('nav_more'),
                    onTap: () => setState(() => _currentIndex = 2),
                  ),
                  _buildDesktopNavItem(
                    index: 3,
                    icon: Icons.settings_rounded,
                    label: locale.t('nav_settings'),
                    onTap: () => setState(() => _currentIndex = 3),
                  ),

                  const Spacer(),

                  // Footer Version
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    child: Text(
                      'v${BrandConfig.version}',
                      style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),

            // Main Content Area
            Expanded(child: _pages[_currentIndex]),
          ],
        ),
      );
    }

    // Mobile Bottom Navigation Bar
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: _pages[_currentIndex],
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          border: Border(top: BorderSide(color: AppTheme.cardBorder, width: 1)),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          backgroundColor: Colors.transparent,
          elevation: 0,
          selectedItemColor: AppTheme.primary,
          unselectedItemColor: AppTheme.textMuted,
          onTap: (index) => setState(() => _currentIndex = index),
          items: [
            BottomNavigationBarItem(
              icon: const Icon(Icons.home_outlined),
              label: locale.t('nav_home'),
            ),
            BottomNavigationBarItem(
              icon: const Icon(Icons.shopping_bag_outlined),
              label: locale.t('nav_store'),
            ),
            BottomNavigationBarItem(
              icon: const Icon(Icons.more_horiz_rounded),
              label: locale.t('nav_more'),
            ),
            BottomNavigationBarItem(
              icon: const Icon(Icons.settings_rounded),
              label: locale.t('nav_settings'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopNavItem({
    required int index,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final isSelected = _currentIndex == index;
    const selectedBg = Color(0xFFE0EDFF);
    const selectedColor = Color(0xFF36618E);
    const unselectedColor = AppTheme.textPrimary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? selectedBg : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: isSelected ? selectedColor : unselectedColor,
                size: 22,
              ),
              const SizedBox(width: 16),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? selectedColor : unselectedColor,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopActionItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: AppTheme.textPrimary,
                size: 22,
              ),
              const SizedBox(width: 16),
              Text(
                label,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w400,
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
