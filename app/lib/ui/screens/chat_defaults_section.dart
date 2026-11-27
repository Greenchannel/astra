import 'package:flutter/material.dart';

import '../../app.dart';
import '../theme.dart';
import '../widgets/common.dart';

class ChatDefaultsSection extends StatefulWidget {
  const ChatDefaultsSection({super.key});

  @override
  State<ChatDefaultsSection> createState() => _ChatDefaultsSectionState();
}

class _ChatDefaultsSectionState extends State<ChatDefaultsSection> {
  final _prompt = TextEditingController();
  final _maxTokens = TextEditingController();
  final _temperature = TextEditingController();
  bool _loaded = false;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final settings = AstraScope.of(context).settings;
    _prompt.text = settings.defaultSystemPrompt;
    _maxTokens.text = '${settings.maxTokens}';
    _temperature.text =
        settings.temperature == null ? '' : '${settings.temperature}';
  }

  @override
  void dispose() {
    _prompt.dispose();
    _maxTokens.dispose();
    _temperature.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AstraScope.of(context);
    final settings = controller.settings;
    final palette = AstraPalette.of(context);
    return AstraSurface(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(
            title: '默认对话设置',
            subtitle: '新对话会继承这些设置；每个对话也可以单独覆盖系统提示词',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _prompt,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: '默认系统提示词',
              hintText: '可以完全留空，留空则不发送 system prompt',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _maxTokens,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '最大输出 tokens',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _temperature,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '温度（留空不发送）',
                    hintText: '0 – 2',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('显示思维链'),
            subtitle: Text(
              'Anthropic 同时会请求 adaptive thinking 摘要',
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
            value: settings.showReasoning,
            onChanged: (value) async {
              settings.showReasoning = value;
              await controller.persistSettings();
            },
          ),
          Row(
            children: [
              Text(
                '这些设置会随配对同步到其他设备。',
                style: TextStyle(color: palette.muted, fontSize: 11.5),
              ),
              const Spacer(),
              FilledButton.tonal(
                onPressed: _saving ? null : _save,
                child: const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final controller = AstraScope.of(context);
    final settings = controller.settings;
    final maxTokens = int.tryParse(_maxTokens.text.trim());
    if (maxTokens == null || maxTokens < 1 || maxTokens > 200000) {
      showAppSnack(context, '最大 tokens 需要是 1–200000 的整数。');
      return;
    }
    final temperatureText = _temperature.text.trim();
    double? temperature;
    if (temperatureText.isNotEmpty) {
      temperature = double.tryParse(temperatureText);
      if (temperature == null || temperature < 0 || temperature > 2) {
        showAppSnack(context, '温度需要是 0–2 的数字，或留空。');
        return;
      }
    }
    setState(() => _saving = true);
    try {
      settings
        ..defaultSystemPrompt = _prompt.text
        ..maxTokens = maxTokens
        ..temperature = temperature;
      await controller.persistSettings();
      if (mounted) showAppSnack(context, '默认对话设置已保存');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
