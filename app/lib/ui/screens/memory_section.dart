import 'package:flutter/material.dart';

import '../../app.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'memory_screen.dart';

class MemorySection extends StatefulWidget {
  const MemorySection({super.key});

  @override
  State<MemorySection> createState() => _MemorySectionState();
}

class _MemorySectionState extends State<MemorySection> {
  final _summaryTrigger = TextEditingController();
  final _extractInterval = TextEditingController();
  final _maxMemories = TextEditingController();
  bool _loaded = false;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final settings = AstraScope.of(context).settings;
    _summaryTrigger.text = '${settings.summaryTriggerTurns}';
    _extractInterval.text = '${settings.memoryExtractIntervalTurns}';
    _maxMemories.text = '${settings.maxMemoryEntries}';
  }

  @override
  void dispose() {
    _summaryTrigger.dispose();
    _extractInterval.dispose();
    _maxMemories.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AstraScope.of(context);
    final settings = controller.settings;
    final palette = AstraPalette.of(context);
    final memoryCount = controller.memories.length;

    return AstraSurface(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(
            title: '记忆与上下文压缩',
            subtitle: '长对话定期总结早期上下文；跨对话定期提取并压缩去重长期记忆',
            trailing: TextButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const MemoryScreen()),
                );
              },
              icon: const Icon(Icons.psychology_alt_outlined, size: 17),
              label: Text('管理 ($memoryCount)'),
            ),
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用跨对话长期记忆'),
            subtitle: Text(
              '每次请求时作为背景参考注入系统提示词',
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
            value: settings.enableMemory,
            onChanged: (value) async {
              settings.enableMemory = value;
              await controller.persistSettings();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('定期自动提取与总结压缩'),
            subtitle: Text(
              '按对话轮次自动提取新记忆，并定期合并去重、解决冲突',
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
            value: settings.autoExtractMemory,
            onChanged: settings.enableMemory
                ? (value) async {
                    settings.autoExtractMemory = value;
                    await controller.persistSettings();
                  }
                : null,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('长对话自动总结压缩'),
            subtitle: Text(
              '超出阈值时把早期消息压缩为摘要，保留近期对话原文以节省 Token',
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
            value: settings.enableAutoSummary,
            onChanged: (value) async {
              settings.enableAutoSummary = value;
              await controller.persistSettings();
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _summaryTrigger,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '对话压缩阈值（条）',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _extractInterval,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '记忆提取间隔（轮）',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _maxMemories,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '记忆压缩上限（条）',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton.icon(
                onPressed: _saving || controller.memoryBusy || memoryCount <= 1
                    ? null
                    : _compressNow,
                icon: const Icon(Icons.compress, size: 17),
                label: const Text('立即压缩整理'),
              ),
              const Spacer(),
              FilledButton.tonal(
                onPressed: _saving ? null : _save,
                child: const Text('保存参数'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final controller = AstraScope.of(context);
    final trigger = int.tryParse(_summaryTrigger.text.trim());
    final interval = int.tryParse(_extractInterval.text.trim());
    final maxEntries = int.tryParse(_maxMemories.text.trim());
    if (trigger == null || trigger < 6 || trigger > 200) {
      showAppSnack(context, '对话压缩阈值需为 6–200 的整数。');
      return;
    }
    if (interval == null || interval < 2 || interval > 100) {
      showAppSnack(context, '记忆提取间隔需为 2–100 的整数。');
      return;
    }
    if (maxEntries == null || maxEntries < 5 || maxEntries > 200) {
      showAppSnack(context, '记忆压缩上限需为 5–200 的整数。');
      return;
    }
    setState(() => _saving = true);
    try {
      controller.settings
        ..summaryTriggerTurns = trigger
        ..memoryExtractIntervalTurns = interval
        ..maxMemoryEntries = maxEntries;
      await controller.persistSettings();
      if (mounted) showAppSnack(context, '记忆与压缩设置已保存');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _compressNow() async {
    final controller = AstraScope.of(context);
    setState(() => _saving = true);
    try {
      final count = await controller.compressMemoriesNow();
      if (mounted) showAppSnack(context, '已总结压缩为 $count 条长期记忆');
    } catch (error) {
      if (mounted) showAppSnack(context, '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
