import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../config/app_theme.dart';
import '../../state/locale_provider.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleProvider>();

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(
          locale.t('nav_more'),
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        centerTitle: false,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        children: [
          // Group 1: 申请代理 & 官方网站
          _buildCard(
            children: [
              _buildListItem(
                context: context,
                iconData: Icons.handshake_rounded,
                title: locale.t('apply_agent'),
                isFirst: true,
                onTap: () => _showAgentDialog(context),
              ),
              const Divider(height: 1, thickness: 1, color: AppTheme.cardBorder),
              _buildListItem(
                context: context,
                iconData: Icons.public_rounded,
                title: locale.t('official_website'),
                isLast: true,
                onTap: () => _showWebsiteDialog(context),
              ),
            ],
          ),

          // Group 2: 财务 (我的订单)
          _buildSectionHeader(locale.t('sec_finance')),
          _buildCard(
            children: [
              _buildListItem(
                context: context,
                iconData: Icons.assignment_rounded,
                title: locale.t('my_orders'),
                isFirst: true,
                isLast: true,
                onTap: () => _showOrdersDialog(context),
              ),
            ],
          ),

          // Group 3: 客服支持 (在线客服、官方频道、工单列表)
          _buildSectionHeader(locale.t('sec_support')),
          _buildCard(
            children: [
              _buildListItem(
                context: context,
                iconData: Icons.assignment_ind_rounded,
                title: locale.t('online_service'),
                isFirst: true,
                onTap: () => _showLiveSupportDialog(context),
              ),
              const Divider(height: 1, thickness: 1, color: AppTheme.cardBorder),
              _buildListItem(
                context: context,
                iconData: Icons.campaign_rounded,
                title: locale.t('official_channel'),
                onTap: () => _showChannelDialog(context),
              ),
              const Divider(height: 1, thickness: 1, color: AppTheme.cardBorder),
              _buildListItem(
                context: context,
                iconData: Icons.mark_chat_unread_rounded,
                title: locale.t('ticket_list'),
                isLast: true,
                onTap: () => _showTicketsDialog(context),
              ),
            ],
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

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

  Widget _buildListItem({
    required BuildContext context,
    required IconData iconData,
    Color? iconColor,
    Color? iconBgColor,
    required String title,
    required VoidCallback onTap,
    bool isFirst = false,
    bool isLast = false,
  }) {
    final defaultIconBg = AppTheme.background;
    final defaultIconColor = Colors.black;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Row(
            children: [
              // Icon Container
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconBgColor ?? defaultIconBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.cardBorder),
                ),
                child: Center(
                  child: Icon(iconData, color: iconColor ?? defaultIconColor, size: 24),
                ),
              ),
              const SizedBox(width: 16),
              // Item Title
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              // Chevron Right Indicator
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

  // --- Interaction Dialogs ---

  void _showAgentDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Row(
          children: [
            Icon(Icons.handshake_rounded, color: Color(0xFF16A34A)),
            SizedBox(width: 10),
            Text('申请代理合作', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '欢迎加入 AeroVPN 商业分销伙伴网络：',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
            const SizedBox(height: 12),
            _buildDialogBullet('30% ~ 50% 阶梯式高额佣金分成，每月稳定结算'),
            _buildDialogBullet('独立代理商分销后台，用户充值与流量实时监控'),
            _buildDialogBullet('支持专属品牌贴牌、私有客户端定制开发与白标服务'),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFDCFCE7),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                children: [
                  Icon(Icons.contact_mail_outlined, color: Color(0xFF16A34A), size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '商务合作 Telegram: @AeroVPN_Partner\n商务邮箱: partner@aerovpn.com',
                      style: TextStyle(fontSize: 12, color: Color(0xFF14532D), height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  void _showWebsiteDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Row(
          children: [
            Icon(Icons.public_rounded, color: Color(0xFFEA580C)),
            SizedBox(width: 10),
            Text('官方网站', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('AeroVPN 官方主站地址：'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFEDD5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const SelectableText(
                'https://aerovpn.com',
                style: TextStyle(
                  color: Color(0xFF9A3412),
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '如遇网络阻断，请收藏最新防失联备用发布页。',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showOrdersDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Row(
          children: [
            Icon(Icons.assignment_rounded, color: Color(0xFF0284C7)),
            SizedBox(width: 10),
            Text('我的订单记录', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildOrderItem('ORD-20261006-9021', '白羊座 Pro 尊享套餐 (365天)', '¥ 188.00', '生效中', true),
              const Divider(height: 1),
              _buildOrderItem('ORD-20260401-3810', '白羊座 流量充值包 100GB', '¥ 28.00', '已完成', false),
              const Divider(height: 1),
              _buildOrderItem('ORD-20251006-1102', '金牛座 标准套餐 (180天)', '¥ 98.00', '已到期', false),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _buildOrderItem(String id, String plan, String amount, String status, bool isActive) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(plan, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(height: 3),
                Text('单号: $id', style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(amount, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              const SizedBox(height: 3),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isActive ? const Color(0xFFDCFCE7) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  status,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: isActive ? const Color(0xFF16A34A) : const Color(0xFF64748B),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showLiveSupportDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Row(
          children: [
            Icon(Icons.assignment_ind_rounded, color: Color(0xFFEF4444)),
            SizedBox(width: 10),
            Text('在线客服', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'AeroVPN 7x24 小时全球运维技术客服：',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            _buildDialogBullet('平均响应时间 < 2 分钟'),
            _buildDialogBullet('全天候线路拥塞调优与节点更换支援'),
            _buildDialogBullet('多平台客户端连接排查协助'),
            const SizedBox(height: 14),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已为您接通专属在线客服支持通道')),
                );
              },
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
              label: const Text('开始即时对话'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 44),
                backgroundColor: const Color(0xFFEF4444),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showChannelDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Row(
          children: [
            Icon(Icons.campaign_rounded, color: Color(0xFF7C3AED)),
            SizedBox(width: 10),
            Text('官方频道', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '订阅 AeroVPN 官方 Telegram 广播频道：',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            _buildDialogBullet('新节点部署与全球 BGP 扩容通知'),
            _buildDialogBullet('重大协议升级（如 sing-box 新版 Reality 特性）'),
            _buildDialogBullet('官方节假日独家优惠码与福利活动'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFEDE9FE),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const SelectableText(
                'https://t.me/AeroVPN_Official',
                style: TextStyle(
                  color: Color(0xFF5B21B6),
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showTicketsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Row(
          children: [
            Icon(Icons.mark_chat_unread_rounded, color: Color(0xFF9333EA)),
            SizedBox(width: 10),
            Text('工单列表', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTicketItem('TK-202610-098', '东京 03 号节点延迟调优请求', '已回复', const Color(0xFF16A34A)),
              const Divider(height: 1),
              _buildTicketItem('TK-202609-041', 'Windows 驱动 TUN 虚拟网卡安装咨询', '已结单', const Color(0xFF64748B)),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('工单创建窗口已打开，客服将在 15 分钟内答复')),
                  );
                },
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('新建工单'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 42),
                  side: const BorderSide(color: Color(0xFF9333EA)),
                  foregroundColor: const Color(0xFF9333EA),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _buildTicketItem(String id, String title, String status, Color statusColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                const SizedBox(height: 3),
                Text('工单号: $id', style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              status,
              style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDialogBullet(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('• ', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
        ],
      ),
    );
  }
}
