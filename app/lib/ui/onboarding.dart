import 'package:flutter/material.dart';

import '../app.dart';
import '../ui/theme.dart';
import 'screens/provider_edit_screen.dart';
import 'widgets/common.dart';

class OnboardingView extends StatelessWidget {
  const OnboardingView({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AstraScope.of(context);
    final palette = AstraPalette.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const BrandMark(),
              const SizedBox(height: 28),
              Text(
                '一个安静、可靠的 AI 工作台',
                style: Theme.of(context).textTheme.displaySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                '桌面与 Android 都能用。模型、图片、代码工具与聊天记录都留在你自己的设备上。',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.muted, height: 1.6),
              ),
              const SizedBox(height: 30),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: const [
                  _Feature(
                    icon: Icons.hub_outlined,
                    title: '多模型',
                    body: '一个 Base URL 下管理多个模型',
                  ),
                  _Feature(
                    icon: Icons.photo_outlined,
                    title: '图片对话',
                    body: '上传图片给视觉模型',
                  ),
                  _Feature(
                    icon: Icons.terminal_outlined,
                    title: '本地工具',
                    body: 'Python、Shell、联网搜索',
                  ),
                  _Feature(
                    icon: Icons.wifi_tethering,
                    title: '配对同步',
                    body: '局域网输入配对码即同步',
                  ),
                ],
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ProviderEditScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.add),
                label: const Text('添加模型服务'),
              ),
              const SizedBox(height: 12),
              Text(
                controller.accounts.isEmpty
                    ? '添加后会引导你拉取可用模型'
                    : '已有 ${controller.accounts.length} 个服务，新建一个对话开始',
                style: TextStyle(color: palette.muted, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    return AstraSurface(
      padding: const EdgeInsets.all(14),
      child: SizedBox(
        width: 160,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: palette.accent),
            const SizedBox(height: 10),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              body,
              style: TextStyle(color: palette.muted, fontSize: 12, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}

class NoConversationView extends StatelessWidget {
  const NoConversationView({super.key, required this.onAddProvider});

  final VoidCallback onAddProvider;

  @override
  Widget build(BuildContext context) {
    final controller = AstraScope.of(context);
    if (controller.accounts.isEmpty) {
      return const OnboardingView();
    }
    return EmptyHint(
      title: '开始一段新对话',
      body: '选择一个模型服务，和 Astra 聊聊。也可以先到设置中拉取更多模型。',
      icon: Icons.chat_bubble_outline,
      action: FilledButton.icon(
        onPressed: () {
          final conversation = controller.newConversation();
          if (conversation == null && controller.accounts.isEmpty) {
            onAddProvider();
          }
        },
        icon: const Icon(Icons.add_comment_outlined),
        label: const Text('新对话'),
      ),
    );
  }
}
