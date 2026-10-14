import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../config/app_theme.dart';
import '../../state/locale_provider.dart';

class FaqScreen extends StatefulWidget {
  const FaqScreen({super.key});

  @override
  State<FaqScreen> createState() => _FaqScreenState();
}

class _FaqScreenState extends State<FaqScreen> {
  // Store expanded state for each FAQ item (by default, first item can be expanded or all collapsed)
  final Set<int> _expandedIndices = {0};

  final List<Map<String, dynamic>> _faqItems = const [
    {
      'question': '节点全红怎么办？',
      'answer':
          '请将网络环境切换为移动蜂窝数据,执行断开并重连操作。注:部分运营商可能会存在瞬时阻断,如重连失败,请于5-15分钟后重试。',
    },
    {
      'question': '安卓点击按钮没反应？',
      'answer':
          '为了保证正常启动,请您先开启软件的通知权限。另外,请确认手机设置-VPN设置里有没有其他VPN开启了‘始终连接’如果有请关闭它,并手动退出校园网VPN软件,否则可能会因为冲突导致无法连接。',
    },
    {
      'question': '电脑端连接报错？',
      'bullets': [
        '彻底退出杀毒软件和可能占用端口的其他工具,重启电脑后再重新连接。如果看到‘IPv6’相关的报错,通常是因为网卡配置未开启,您可以咨询客服解决。',
        '注意:若有软件开机自启,请先手动退出再启动本客户端。',
        '部分电脑系统不支持开启“虚拟网卡模式”请再设置里改成“普通模式”再尝试连接。',
      ],
    },
    {
      'question': '电脑端初始化失败？',
      'bullets': [
        '网络环境排查：请尝试切换网络环境（如：由 Wi-Fi 切换至手机热点）以排除本地网络阻断问题。',
        '版本更新异常：若更新后出现此问题，请务必彻底卸载当前版本（确保无文件残留），随后前往官网下载最新客户端重新安装。',
        'PC 端专属方案：若电脑端提示初始化失败，请前往官网文档下载并安装系统证书。',
        '终极方案：若以上操作均无效，请清理所有残留文件后重新安装最新版。',
      ],
    },
    {
      'question': '电脑端启动出现 xxx.dll 错误？',
      'answer':
          '若启动提示缺失 .dll 文件，说明系统缺少必要的微软 VC++ 运行库（Redistributable）。请前往【使用文档】下载并安装运行库合集，重启软件即可解决。（注：win7系统不支持）',
    },
    {
      'question': 'Mac系统出现软件闪退？',
      'answer':
          '首次打开请在“隐私与安全性”中授予信任。软件启动后图标位于屏幕顶部导航栏。如遇闪退，请尝试重启电脑或重新安装客户端。',
    },
    {
      'question': '关于电脑端虚拟网卡模式',
      'answer':
          '默认模式仅代理浏览器。若要加速 Telegram 或 Codex 等第三方软件，请开启“虚拟网卡模式”以接管全流量。注：部分校园网环境可能存在限制，请视实际情况测试使用。',
    },
    {
      'question': '关于路由模式介绍',
      'bullets': [
        '自动模式（推荐）：系统默认选项。仅代理海外流量，国内网站通过本地网络直连。由于依赖规则匹配，若遇到部分海外站点无法访问，请尝试切换模式。',
        '全局模式：所有网络请求均通过代理服务器。',
      ],
      'footer':
          '注意：开启后，国内应用（如抖音、小红书）的 IP 属地将显示为代理节点所在地，且国内网络的响应延迟可能会有所增加。',
    },
  ];

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LocaleProvider>();

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          locale.t('faq_title'),
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        titleSpacing: 0,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        backgroundColor: AppTheme.background,
      ),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        itemCount: _faqItems.length,
        separatorBuilder: (context, index) => const SizedBox(height: 14),
        itemBuilder: (context, index) {
          final item = _faqItems[index];
          final isExpanded = _expandedIndices.contains(index);

          return _buildFaqCard(
            index: index,
            item: item,
            isExpanded: isExpanded,
          );
        },
      ),
    );
  }

  Widget _buildFaqCard({
    required int index,
    required Map<String, dynamic> item,
    required bool isExpanded,
  }) {
    final question = item['question'] as String;
    final answer = item['answer'] as String?;
    final bullets = item['bullets'] as List<String>?;
    final footer = item['footer'] as String?;

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder, width: 1.2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Material(
          color: Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: () {
                  setState(() {
                    if (isExpanded) {
                      _expandedIndices.remove(index);
                    } else {
                      _expandedIndices.add(index);
                    }
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          question,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Icon(
                        isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                        color: const Color(0xFF334155),
                        size: 24,
                      ),
                    ],
                  ),
                ),
              ),
              if (isExpanded) ...[
                Padding(
                  padding: const EdgeInsets.only(left: 20, right: 20, bottom: 20),
                  child: SizedBox(
                    width: double.infinity,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (answer != null)
                          Text(
                            answer,
                            textAlign: TextAlign.left,
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 13,
                              height: 1.6,
                            ),
                          ),
                        if (bullets != null) ...[
                          for (final b in bullets) ...[
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '• ',
                                    style: TextStyle(
                                      color: Color(0xFF334155),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      b,
                                      textAlign: TextAlign.left,
                                      style: const TextStyle(
                                        color: AppTheme.textSecondary,
                                        fontSize: 13,
                                        height: 1.55,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                        if (footer != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            footer,
                            textAlign: TextAlign.left,
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
