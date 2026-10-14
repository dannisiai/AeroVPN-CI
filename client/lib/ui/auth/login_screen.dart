import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../config/app_theme.dart';
import '../../config/brand_config.dart';
import '../../state/account_provider.dart';
import '../../state/auth_provider.dart';
import '../../state/locale_provider.dart';
import '../../state/region_provider.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isSignUp = false;
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  int _countdown = 0;
  Timer? _countdownTimer;

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _emailController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _startCountdown() {
    setState(() => _countdown = 60);
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdown > 1) {
        setState(() => _countdown--);
      } else {
        _countdownTimer?.cancel();
        setState(() => _countdown = 0);
      }
    });
  }

  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入有效的电子邮箱地址')),
      );
      return;
    }

    final auth = context.read<AuthProvider>();
    final success = await auth.sendVerificationCode(email);
    if (success && mounted) {
      _startCountdown();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('验证码已发送至您的邮箱，请查收！')),
      );
    }
  }

  void _showLanguageSelector(BuildContext context) {
    final locale = context.read<LocaleProvider>();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(locale.t('language'), style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildLangItem(ctx, locale, 'zh', '简体中文 (Simplified Chinese)'),
            _buildLangItem(ctx, locale, 'en', 'English (英文)'),
            _buildLangItem(ctx, locale, 'ja', '日本語 (Japanese)'),
          ],
        ),
      ),
    );
  }

  Widget _buildLangItem(BuildContext ctx, LocaleProvider locale, String langCode, String label) {
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

  void _submit() async {
    final auth = context.read<AuthProvider>();
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final code = _codeController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入邮箱和密码')),
      );
      return;
    }

    if (_isSignUp) {
      if (code.isEmpty || code.length < 6) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请输入收到的6位验证码')),
        );
        return;
      }

      // Registration flow strictly requiring verification code
      final registered = await auth.register(email, password, code);
      if (registered && mounted) {
        final success = await auth.login(email, password);
        if (success && mounted) {
          context.read<AccountProvider>().fetchAccount();
          context.read<RegionProvider>().fetchRegions();
        }
      }
    } else {
      // Login flow
      final success = await auth.login(email, password);
      if (success && mounted) {
        context.read<AccountProvider>().fetchAccount();
        context.read<RegionProvider>().fetchRegions();
      }
    }
  }

  void _showForgotPasswordDialog() {
    final emailCtrl = TextEditingController(text: _emailController.text);
    final locale = context.read<LocaleProvider>();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text(locale.t('forgot_password'), style: const TextStyle(color: AppTheme.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(locale.t('forgot_password_desc'), style: const TextStyle(color: AppTheme.textMuted, fontSize: 13)),
            const SizedBox(height: 16),
            TextField(
              controller: emailCtrl,
              decoration: InputDecoration(labelText: locale.t('email_label')),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(locale.t('cancel'), style: const TextStyle(color: AppTheme.textSecondary))),
          ElevatedButton(
            onPressed: () async {
              final auth = context.read<AuthProvider>();
              final messenger = ScaffoldMessenger.of(context);
              final ok = await auth.forgotPassword(emailCtrl.text.trim());
              if (!mounted) return;
              if (ctx.mounted) {
                Navigator.pop(ctx);
                messenger.showSnackBar(
                  SnackBar(content: Text(ok ? locale.t('reset_send_ok') : (auth.errorMessage ?? 'Request failed'))),
                );
              }
            },
            child: Text(locale.t('send_reset_link')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final locale = context.watch<LocaleProvider>();

    return Scaffold(
      appBar: AppBar(
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.language_rounded, size: 18, color: AppTheme.primary),
            label: Text(
              locale.currentLanguage.toUpperCase(),
              style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold),
            ),
            onPressed: () => _showLanguageSelector(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Brand Icon & Name
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppTheme.cardBorder, width: 1.5),
                    ),
                    child: Center(
                      child: Image.asset(
                        'assets/app_logo.png',
                        width: 42,
                        height: 42,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    BrandConfig.appName,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    locale.t('brand_subtitle'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                  ),
                  const SizedBox(height: 36),

                  // Auth Mode Switcher (Sign In / Sign Up)
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFAF9F5),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.cardBorder),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => _isSignUp = false),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: !_isSignUp ? AppTheme.primary : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Center(
                                child: Text(
                                  locale.t('sign_in'),
                                  style: TextStyle(
                                    color: !_isSignUp ? Colors.white : AppTheme.textSecondary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => _isSignUp = true),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: _isSignUp ? AppTheme.primary : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Center(
                                child: Text(
                                  locale.t('create_account'),
                                  style: TextStyle(
                                    color: _isSignUp ? Colors.white : AppTheme.textSecondary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Email Input
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: locale.t('email_label'),
                      prefixIcon: const Icon(Icons.email_outlined, color: AppTheme.textMuted, size: 20),
                    ),
                  ),
                  if (_isSignUp) ...[
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _codeController,
                            keyboardType: TextInputType.number,
                            maxLength: 6,
                            decoration: const InputDecoration(
                              counterText: '',
                              labelText: '邮箱验证码',
                              hintText: '6位数字验证码',
                              prefixIcon: Icon(Icons.mark_email_read_outlined, color: AppTheme.textMuted, size: 20),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          height: 52,
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.primary,
                              side: const BorderSide(color: AppTheme.primary, width: 1.2),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              padding: const EdgeInsets.symmetric(horizontal: 14),
                            ),
                            onPressed: (_countdown > 0 || auth.isLoading) ? null : _sendCode,
                            child: Text(
                              _countdown > 0 ? '${_countdown}s 后重新发送' : '获取验证码',
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),

                  // Password Input
                  TextField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: locale.t('password_label'),
                      prefixIcon: const Icon(Icons.lock_outline_rounded, color: AppTheme.textMuted, size: 20),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                          color: AppTheme.textMuted,
                          size: 20,
                        ),
                        onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  if (!_isSignUp)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _showForgotPasswordDialog,
                        child: Text(locale.t('forgot_password'), style: const TextStyle(color: AppTheme.primary, fontSize: 13)),
                      ),
                    ),

                  if (auth.errorMessage != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFFECACA)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              auth.errorMessage!,
                              style: const TextStyle(color: Color(0xFFDC2626), fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),

                  // Action Button
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: auth.isLoading ? null : _submit,
                      child: auth.isLoading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                            )
                          : Text(_isSignUp ? locale.t('create_account') : locale.t('sign_in')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
