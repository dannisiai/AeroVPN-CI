import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../config/app_theme.dart';
import '../../config/brand_config.dart';
import '../../state/auth_provider.dart';
import '../../state/locale_provider.dart';
import '../../state/vpn_provider.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final vpn = context.watch<VpnProvider>();
    final locale = context.watch<LocaleProvider>();
    final auth = context.watch<AuthProvider>();

    final currentLangLabel = _getLanguageLabel(locale.currentLanguage);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(
          locale.t('nav_settings'),
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        backgroundColor: AppTheme.background,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        children: [
          // Section 1: 通用
          _buildSectionHeader(locale.t('sec_general')),
          _buildCard(
            children: [
              _buildSettingItem(
                context: context,
                iconData: Icons.language_rounded,
                title: locale.t('language'),
                subtitle: currentLangLabel,
                onTap: () => _showLanguageSelector(context),
              ),
            ],
          ),

          _buildSectionHeader(locale.t('sec_connection_settings')),
          _buildCard(
            children: [
              _buildSettingItem(
                context: context,
                iconData: Icons.alt_route_rounded,
                title: locale.t('connection_mode'),
                subtitle: locale.t(vpn.connectionMode == 'system_proxy' ? 'conn_mode_system_proxy' : 'conn_mode_tun'),
                showChevron: vpn.supportsSystemProxy,
                onTap: vpn.supportsSystemProxy && !vpn.isBusy && vpn.isDisconnected
                    ? () => _showConnectionModeSelector(context)
                    : null,
              ),
              const Divider(height: 1, thickness: 1, color: AppTheme.cardBorder),
              if (vpn.supportsKillSwitch) ...[
                _buildSettingItem(
                  context: context,
                  iconData: Icons.shield_outlined,
                  title: locale.t('kill_switch'),
                  subtitle: locale.t('kill_switch_desc'),
                  showChevron: false,
                  trailingWidget: Switch(
                    value: vpn.killSwitch,
                    onChanged: vpn.isBusy || !vpn.isDisconnected ? null : (value) async {
                      await _saveSetting(context, () => vpn.setKillSwitch(value));
                    },
                  ),
                ),
                const Divider(height: 1, thickness: 1, color: AppTheme.cardBorder),
              ],
              _buildSettingItem(
                context: context,
                iconData: Icons.power_settings_new,
                title: locale.t('auto_connect'),
                subtitle: locale.t('auto_connect_desc'),
                showChevron: false,
                trailingWidget: Switch(
                  value: vpn.autoConnect,
                  onChanged: (value) async {
                    await _saveSetting(context, () => vpn.setAutoConnect(value));
                  },
                ),
              ),
              const Divider(height: 1, thickness: 1, color: AppTheme.cardBorder),
              _buildSettingItem(
                context: context,
                iconData: Icons.lan_outlined,
                title: locale.t('bypass_lan'),
                subtitle: locale.t('bypass_lan_desc'),
                showChevron: false,
                trailingWidget: Switch(
                  value: vpn.bypassLan,
                  onChanged: vpn.isBusy || !vpn.isDisconnected ? null : (value) async {
                    await _saveSetting(context, () => vpn.setBypassLan(value));
                  },
                ),
              ),
            ],
          ),

          // Section 3: 更新与支持
          _buildSectionHeader(locale.t('sec_updates_support')),
          _buildCard(
            children: [
              // 检查更新
              _buildSettingItem(
                context: context,
                iconData: Icons.system_update_rounded,
                title: locale.t('check_updates'),
                subtitle: '${locale.t('current_version_prefix')}${BrandConfig.version}',
                onTap: () => _showUpdateDialog(context, locale),
              ),
              const Divider(height: 1, thickness: 1, color: AppTheme.cardBorder),

              // 服务条款
              _buildSettingItem(
                context: context,
                iconData: Icons.description_rounded,
                title: locale.t('terms_of_service'),
                onTap: () => _showTermsDialog(context, locale),
              ),
              const Divider(height: 1, thickness: 1, color: AppTheme.cardBorder),

              // 隐私政策
              _buildSettingItem(
                context: context,
                iconData: Icons.security_rounded,
                title: locale.t('privacy_policy'),
                onTap: () => _showPrivacyDialog(context, locale),
              ),
              const Divider(height: 1, thickness: 1, color: AppTheme.cardBorder),

              // 关于
              _buildSettingItem(
                context: context,
                iconData: Icons.info_rounded,
                title: locale.t('about'),
                onTap: () => _showAboutDialog(context, locale),
              ),
            ],
          ),

          // Section 4: 账户管理
          _buildSectionHeader(locale.t('sec_account_mgmt')),
          _buildCard(
            children: [
              // 重置密码
              _buildSettingItem(
                context: context,
                iconData: Icons.lock_rounded,
                title: locale.t('reset_password'),
                onTap: () => _showResetPasswordDialog(context, auth, locale),
              ),
              const Divider(height: 1, thickness: 1, color: AppTheme.cardBorder),

              // 退出登录
              _buildSettingItem(
                context: context,
                iconData: Icons.logout_rounded,
                iconColor: Colors.black,
                title: locale.t('log_out'),
                titleColor: const Color(0xFFDC2626),
                showChevron: false,
                onTap: () => _showLogoutDialog(context, auth, locale),
              ),
            ],
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  void _showConnectionModeSelector(BuildContext context) {
    final vpn = context.read<VpnProvider>();
    final locale = context.read<LocaleProvider>();
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in ['tun', 'system_proxy'])
              ListTile(
                title: Text(locale.t(mode == 'tun' ? 'conn_mode_tun' : 'conn_mode_system_proxy')),
                subtitle: Text(locale.t(mode == 'tun' ? 'conn_mode_tun_desc' : 'conn_mode_system_proxy_desc')),
                trailing: vpn.connectionMode == mode ? const Icon(Icons.check) : null,
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await _saveSetting(context, () => vpn.setConnectionMode(mode));
                },
              ),
          ],
        ),
      ),
    );
  }

  // --- UI Components ---

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 10, left: 4),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFF334155),
          fontSize: 14,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _buildCard({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder, width: 1.2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Column(
          children: children,
        ),
      ),
    );
  }

  Widget _buildSettingItem({
    required BuildContext context,
    required IconData iconData,
    required String title,
    String? subtitle,
    Color? iconColor,
    Color? iconBgColor,
    Color? titleColor,
    Widget? trailingWidget,
    VoidCallback? onTap,
    bool showChevron = true,
  }) {
    final defaultIconBg = AppTheme.background;
    final defaultIconColor = Colors.black;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
          child: Row(
            children: [
              // Icon Box
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconBgColor ?? defaultIconBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.cardBorder),
                ),
                child: Center(
                  child: Icon(iconData, color: iconColor ?? defaultIconColor, size: 23),
                ),
              ),
              const SizedBox(width: 16),
              // Titles
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: titleColor ?? AppTheme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle != null && subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Trailing widget or chevron
              if (trailingWidget != null)
                trailingWidget
              else if (showChevron)
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Color(0xFF94A3B8),
                  size: 22,
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _getLanguageLabel(String code) {
    switch (code) {
      case 'zh':
        return '中文 (简体)';
      case 'ja':
        return '日本語 (日本)';
      case 'en':
      default:
        return 'English (US)';
    }
  }

  // --- Dialogs matching video recording ---

  Future<void> _saveSetting(BuildContext context, Future<void> Function() save) async {
    try {
      await save();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  void _showUpdateDialog(BuildContext context, LocaleProvider locale) {
    // Honest: no silent auto-update check is wired in this build.
    // Show current version + manual guidance instead of fake "checked".
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          locale.t('version_update'),
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
        ),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                decoration: BoxDecoration(
                  color: AppTheme.background,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.cardBorder, width: 1.2),
                ),
                child: Column(
                  children: [
                    const Icon(Icons.info_outline_rounded, color: Color(0xFF2563EB), size: 36),
                    const SizedBox(height: 12),
                    Text(
                      '${locale.t('current_version_prefix')}${BrandConfig.version}',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                locale.t('update_manual_note'),
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13, height: 1.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              locale.t('confirm'),
              style: const TextStyle(
                color: AppTheme.primary,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showLanguageSelector(BuildContext context) {
    final locale = context.read<LocaleProvider>();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          locale.t('language'),
          style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildLanguageOption(ctx, locale, 'zh', '中文 (简体)'),
            _buildLanguageOption(ctx, locale, 'en', 'English (US)'),
            _buildLanguageOption(ctx, locale, 'ja', '日本語 (日本)'),
          ],
        ),
      ),
    );
  }

  Widget _buildLanguageOption(BuildContext ctx, LocaleProvider locale, String langCode, String label) {
    final isSelected = locale.currentLanguage == langCode;
    return InkWell(
      onTap: () {
        locale.setLanguage(langCode);
        Navigator.pop(ctx);
      },
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: isSelected ? AppTheme.primary : AppTheme.textMuted,
              size: 20,
            ),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? AppTheme.primary : AppTheme.textPrimary,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showTermsDialog(BuildContext context, LocaleProvider locale) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(locale.t('terms_of_service'), style: const TextStyle(fontWeight: FontWeight.w700)),
        content: const SingleChildScrollView(
          child: Text(
            '1. 用户应遵守所在地与服务器所在地的相关法律法规。\n\n'
            '2. 本服务仅供合法的学术研究、商业出海及隐私保护使用。\n\n'
            '3. 严禁利用本服务从事网络攻击、滥用流量或侵犯他人合法权益之行为。',
            style: TextStyle(fontSize: 13, height: 1.5, color: AppTheme.textSecondary),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(locale.t('i_know'))),
        ],
      ),
    );
  }

  void _showPrivacyDialog(BuildContext context, LocaleProvider locale) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(locale.t('privacy_policy'), style: const TextStyle(fontWeight: FontWeight.w700)),
        content: SingleChildScrollView(
          child: Text(
            '${BrandConfig.appName} 严格遵循无日志审计准则（Strict No-Logs Policy）：\n\n'
            '• 我们绝不记录或存储用户的浏览历史、流量目的地或 DNS 查询。\n'
            '• 采用军工级 ChaCha20-Poly1305 / AES-256-GCM 强加密保护每一次连接。',
            style: const TextStyle(fontSize: 13, height: 1.5, color: AppTheme.textSecondary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              locale.t('confirm'),
              style: const TextStyle(
                color: AppTheme.primary,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAboutDialog(BuildContext context, LocaleProvider locale) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 20, 16),
        title: Text(
          locale.t('about_app'),
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 22,
            color: AppTheme.textPrimary,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.cardBorder, width: 1.2),
                  ),
                  child: Center(
                    child: Image.asset(
                      'assets/app_logo.png',
                      width: 30,
                      height: 30,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      BrandConfig.appName,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 20,
                        color: AppTheme.textPrimary,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'v${BrandConfig.version}',
                      style: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              '感谢您使用 ${BrandConfig.appName}！我们致力于为您提供安全稳定的网络代理服务。',
              style: const TextStyle(
                fontSize: 14,
                color: AppTheme.textSecondary,
                height: 1.5,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              locale.t('confirm'),
              style: const TextStyle(
                color: AppTheme.primary,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showResetPasswordDialog(BuildContext context, AuthProvider auth, LocaleProvider locale) {
    // Real flow: forgotPassword(email) -> code -> resetPassword(email, code, newPassword).
    final emailCtrl = TextEditingController(text: auth.user?.email ?? '');
    final codeCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(locale.t('reset_password'), style: const TextStyle(fontWeight: FontWeight.w700)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: emailCtrl, decoration: InputDecoration(labelText: locale.t('email_label'))),
              const SizedBox(height: 12),
              TextField(controller: codeCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: locale.t('reset_code_label'))),
              const SizedBox(height: 12),
              TextField(controller: passCtrl, obscureText: true, decoration: InputDecoration(labelText: locale.t('new_password_label'))),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(locale.t('cancel'))),
          TextButton(
            onPressed: () async {
              final ok = await auth.forgotPassword(emailCtrl.text.trim());
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text(ok ? locale.t('reset_send_ok') : (auth.errorMessage ?? 'Request failed'))),
                );
              }
            },
            child: Text(locale.t('send_reset_link')),
          ),
          ElevatedButton(
            onPressed: () async {
              final ok = await auth.resetPassword(emailCtrl.text.trim(), codeCtrl.text.trim(), passCtrl.text.trim());
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(ok ? locale.t('reset_ok') : (auth.errorMessage ?? 'Reset failed'))),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF334155),
              foregroundColor: Colors.white,
            ),
            child: Text(locale.t('confirm')),
          ),
        ],
      ),
    );
  }

  void _showLogoutDialog(BuildContext context, AuthProvider auth, LocaleProvider locale) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(locale.t('logout_confirm_title'), style: const TextStyle(fontWeight: FontWeight.w700)),
        content: Text(locale.t('logout_confirm_content')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(locale.t('cancel')),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await auth.logout();
              if (context.mounted && auth.isAuthenticated && auth.errorMessage != null) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(auth.errorMessage!)));
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
            ),
            child: Text(locale.t('log_out')),
          ),
        ],
      ),
    );
  }
}
