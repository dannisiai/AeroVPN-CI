import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../config/app_theme.dart';
import '../../state/account_provider.dart';
import '../../state/auth_provider.dart';
import '../../state/locale_provider.dart';

class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleProvider>();
    final auth = context.watch<AuthProvider>();
    final account = context.watch<AccountProvider>();
    final plan = account.plan;

    final email = auth.user?.email ?? '';
    // Honest empty state: never fabricate a membership. Unknown plan means
    // "no subscription" (matches backend plan_none/expired), not Pro.
    final planName = plan?.name ?? '未开通会员';
    final isActive = plan?.isActive ?? false;
    final remainingDays = plan?.remainingDays ?? 0;
    final expiryFormatted = plan != null && plan.expiresAt > 0
        ? DateFormat('MMMM d, yyyy').format(plan.expiryDate)
        : '--';

    return Scaffold(
      appBar: AppBar(title: Text(locale.t('account_title'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // User Profile Header
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppTheme.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: AppTheme.primary.withValues(alpha: 0.15),
                    child: const Icon(Icons.person_rounded, color: AppTheme.primary, size: 30),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          email,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: isActive ? AppTheme.statusConnected : AppTheme.statusDisconnected,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              isActive ? locale.t('active_member') : locale.t('expired'),
                              style: TextStyle(
                                color: isActive ? AppTheme.statusConnected : AppTheme.statusDisconnected,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Subscription Plan Card
            Text(
              locale.t('curr_subscription'),
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFFFAF9F5),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.cardBorder, width: 1.2),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        planName,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppTheme.statusConnected.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '$remainingDays ${locale.t('days_left')}',
                          style: const TextStyle(
                            color: AppTheme.statusConnected,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(locale.t('valid_until'), style: const TextStyle(color: AppTheme.textMuted, fontSize: 13)),
                      Text(expiryFormatted, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w700)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(locale.t('simultaneous_devices'), style: const TextStyle(color: AppTheme.textMuted, fontSize: 13)),
                      Text('${plan?.currentDevices ?? 0} / ${plan?.maxDevices ?? 0}', style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w700)),
                    ],
                  ),
                  if (!isActive) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF3C7),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFFDE68A)),
                      ),
                      child: Text(
                        locale.t('no_plan_hint'),
                        style: const TextStyle(color: Color(0xFF92400E), fontSize: 12, height: 1.5),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 32),

            // Logout Button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.logout_rounded, color: AppTheme.statusDisconnected, size: 18),
                label: Text(locale.t('log_out'), style: const TextStyle(color: AppTheme.statusDisconnected, fontWeight: FontWeight.w700)),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: AppTheme.statusDisconnected.withValues(alpha: 0.4)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: AppTheme.card,
                      title: Text(locale.t('logout_confirm_title'), style: const TextStyle(color: AppTheme.textPrimary)),
                      content: Text(locale.t('logout_confirm_content')),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(locale.t('cancel'), style: const TextStyle(color: AppTheme.textSecondary)),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.statusDisconnected),
                          onPressed: () {
                            Navigator.pop(ctx);
                            auth.logout();
                          },
                          child: Text(locale.t('log_out')),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
