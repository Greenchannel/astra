import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/models/models.dart';
import '../theme.dart';
import '../widgets/common.dart';

class ToolsSection extends StatefulWidget {
  const ToolsSection({super.key});

  @override
  State<ToolsSection> createState() => _ToolsSectionState();
}

class _ToolsSectionState extends State<ToolsSection> {
  final _pythonPath = TextEditingController();
  final _searchKey = TextEditingController();
  bool _loaded = false;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _pythonPath.text = AstraScope.of(context).settings.pythonPath;
  }

  @override
  void dispose() {
    _pythonPath.dispose();
    _searchKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AstraScope.of(context);
    final settings = controller.settings;
    final palette = AstraPalette.of(context);
    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final provider = settings.searchProvider;

    return AstraSurface(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(
            title: '工具',
            subtitle: '代码执行与联网搜索需要模型支持 tool calling，并且每次执行都受审批保护',
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('允许执行 Python'),
            subtitle: Text(
              isAndroid
                  ? '使用 App 内置的 Chaquopy Python（标准库）'
                  : '在对话工作目录中调用本机 Python，需要审批',
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
            value: settings.enableCodeTools,
            onChanged: (value) async {
              settings.enableCodeTools = value;
              await controller.persistSettings();
            },
          ),
          if (!isAndroid)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _pythonPath,
                      decoration: const InputDecoration(
                        labelText: 'Python 可执行文件',
                        hintText: 'python 或 /usr/bin/python3',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: () async {
                      settings.pythonPath = _pythonPath.text.trim().isEmpty
                          ? 'python'
                          : _pythonPath.text.trim();
                      await controller.persistSettings();
                      if (context.mounted) showAppSnack(context, 'Python 路径已保存');
                    },
                    child: const Text('保存'),
                  ),
                ],
              ),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('允许执行 Shell 命令'),
            subtitle: Text(
              isAndroid ? '仅桌面端支持' : '高风险，默认关闭；仅在你完全信任模型时开启',
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
            value: settings.enableShellTool && !isAndroid,
            onChanged: isAndroid
                ? null
                : (value) async {
                    settings.enableShellTool = value;
                    await controller.persistSettings();
                  },
          ),
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('联网搜索工具'),
            subtitle: Text(
              '让模型可以搜索最新信息；免费方案使用 DuckDuckGo',
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
            value: settings.enableWebSearch,
            onChanged: (value) async {
              settings.enableWebSearch = value;
              await controller.persistSettings();
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: '搜索提供商'),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<SearchProvider>(
                      value: provider,
                      isExpanded: true,
                      items: SearchProvider.values
                          .map(
                            (item) => DropdownMenuItem(
                              value: item,
                              child: Text(item.label),
                            ),
                          )
                          .toList(),
                      onChanged: (value) async {
                        if (value == null) return;
                        settings.searchProvider = value;
                        await controller.persistSettings();
                        setState(() {});
                      },
                    ),
                  ),
                ),
              ),
              if (provider != SearchProvider.duckduckgo) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _searchKey,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: '${provider.label} API Key',
                      hintText: controller.hasSearchKey(provider)
                          ? '已保存，留空保持'
                          : '粘贴 Key',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _saving
                      ? null
                      : () async {
                          setState(() => _saving = true);
                          try {
                            await controller.saveSearchKey(
                              provider,
                              _searchKey.text,
                            );
                            _searchKey.clear();
                            if (context.mounted) {
                              showAppSnack(context, '搜索 Key 已保存');
                            }
                          } catch (error) {
                            if (context.mounted) showAppSnack(context, '$error');
                          } finally {
                            if (mounted) setState(() => _saving = false);
                          }
                        },
                  child: const Text('保存'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: palette.warning.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: palette.warning.withValues(alpha: 0.25)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.shield_outlined, size: 17, color: palette.warning),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    '代码与 Shell 不是操作系统级强沙箱。Astra 会限制工作目录、'
                    '超时和输出长度，并在每次执行前要求确认；请不要运行来源不明的代码。',
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
