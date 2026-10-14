import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../config/app_theme.dart';
import '../../core/vpn/vpn_status.dart';
import '../../state/locale_provider.dart';

class ConnectButton extends StatefulWidget {
  final VpnStatus status;
  final VoidCallback onTap;

  const ConnectButton({super.key, required this.status, required this.onTap});

  @override
  State<ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<ConnectButton> with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleProvider>();
    final isConnected = widget.status == VpnStatus.connected;
    final isDisconnecting = widget.status == VpnStatus.disconnecting;
    final isConnecting = widget.status == VpnStatus.connecting || widget.status == VpnStatus.reconnecting || isDisconnecting;

    String actionText;
    if (isDisconnecting) {
      actionText = locale.t('status_disconnecting');
    } else if (isConnected) {
      actionText = locale.t('click_to_disconnect');
    } else if (isConnecting) {
      actionText = locale.t('establishing_tunnel');
    } else {
      actionText = locale.t('click_to_connect');
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: GestureDetector(
            onTap: isDisconnecting ? null : widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: _isHovered ? 174 : 170,
              height: _isHovered ? 174 : 170,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isConnected
                    ? AppTheme.statusConnected
                    : (isConnecting ? const Color(0xFFF59E0B) : AppTheme.surface),
                border: Border.all(
                  color: isConnected
                      ? AppTheme.statusConnected
                      : (isConnecting
                          ? const Color(0xFFF59E0B)
                          : (_isHovered ? AppTheme.primary : AppTheme.cardBorder)),
                  width: 2.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: isConnected
                        ? AppTheme.statusConnected.withValues(alpha: 0.35)
                        : (isConnecting
                            ? const Color(0xFFF59E0B).withValues(alpha: 0.35)
                            : (_isHovered
                                ? const Color(0x22000000)
                                : const Color(0x12000000))),
                    blurRadius: _isHovered ? 36 : 28,
                    spreadRadius: _isHovered ? 3 : 1,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Center(
                child: isConnecting
                    ? const SizedBox(
                        width: 58,
                        height: 58,
                        child: CircularProgressIndicator(
                          strokeWidth: 4.5,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : Image.asset(
                        'assets/app_logo.png',
                        width: 76,
                        height: 76,
                        fit: BoxFit.contain,
                        color: isConnected ? Colors.white : Colors.black,
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          actionText,
          style: TextStyle(
            color: isConnected ? AppTheme.statusConnected : AppTheme.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
  }
}
