import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/models/models.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'chat_defaults_section.dart';
import 'memory_section.dart';
import 'provider_edit_screen.dart';
import 'sync_section.dart';
import 'tools_section.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AstraScope.of(context);
    final palette = AstraPalette.of(context);
    final accounts = controller.accounts;
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 42),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '设置',
                      style: Theme.of(context).textTheme.displaySmall,
                    ),
                    const Spacer(),
                    BrandMark(compact: true),
                  ],
                ),
                const SizedBox(height: 22),
                AstraSurface(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionTitle(
                        title: '模型服务',
                        subtitle: '一个 Base URL 可管理多个模型；API Key 仅保存在本机',
                        trailing: TextButton.icon(
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const ProviderEditScreen(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('添加'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (accounts.isEmpty)
                        Text(
                          '还没有模型服务。添加一个 OpenAI 兼容或 Anthropic 服务后即可开始。',
                          style: TextStyle(color: palette.muted, height: 1.5),
                        )
                      else
                        ...accounts.map((account) {
                          final modelCount =
                              controller.modelsFor(account.id, enabledOnly: false).length;
                          final hasKey = controller.hasAccountKey(account.id);
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: palette.accentSoft,
                                borderRadius: BorderRadius.circular(11),
                              ),
                              child: Icon(
                                account.format == ProviderFormat.anthropic
                                    ? Icons.auto_awesome_outlined
                                    : Icons.bolt_outlined,
                                size: 18,
                                color: palette.accent,
                              ),
                            ),
                            title: Text(account.name),
                            subtitle: Text(
                              '${account.format.protocolLabel} · $modelCount 个模型 · '
                              '${hasKey ? 'Key 已配置' : '未配置 Key'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: palette.muted, fontSize: 12),
                            ),
                            trailing: const Icon(Icons.chevron_right, size: 19),
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => ProviderEditScreen(
                                    accountId: account.id,
                                  ),
                                ),
                              );
                            },
                          );
                        }),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                const ChatDefaultsSection(),
                const SizedBox(height: 14),
                const MemorySection(),
                const SizedBox(height: 14),
                const ToolsSection(),
                const SizedBox(height: 14),
                const SyncSection(),
                const SizedBox(height: 14),
                AstraSurface(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionTitle(
                        title: '外观',
                        subtitle: '主题只影响本机，不参与同步',
                      ),
                      const SizedBox(height: 12),
                      SegmentedButton<ThemePreference>(
                        segments: const [
                          ButtonSegment(
                            value: ThemePreference.system,
                            label: Text('跟随系统'),
                          ),
                          ButtonSegment(
                            value: ThemePreference.light,
                            label: Text('浅色'),
                          ),
                          ButtonSegment(
                            value: ThemePreference.dark,
                            label: Text('深色'),
                          ),
                        ],
                        selected: {controller.settings.theme},
                        showSelectedIcon: false,
                        onSelectionChanged: (selection) {
                          controller.setTheme(selection.first);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    'Astra GUI 0.1.0 · local-first\n聊天、图片与设置保存在本机应用目录。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 11.5,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
