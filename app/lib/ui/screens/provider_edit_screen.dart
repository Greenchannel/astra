import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/models/models.dart';
import '../../state/astra_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';

class ProviderEditScreen extends StatefulWidget {
  const ProviderEditScreen({super.key, this.accountId});

  final String? accountId;

  @override
  State<ProviderEditScreen> createState() => _ProviderEditScreenState();
}

class _ProviderEditScreenState extends State<ProviderEditScreen> {
  final _name = TextEditingController();
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  ProviderFormat _format = ProviderFormat.openai;
  String? _accountId;
  bool _loaded = false;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final controller = AstraScope.of(context);
    _accountId = widget.accountId;
    final account =
        _accountId == null ? null : controller.repo.account(_accountId!);
    if (account != null) {
      _name.text = account.name;
      _baseUrl.text = account.baseUrl;
      _format = account.format;
    } else {
      _name.text = 'OpenAI 兼容';
      _baseUrl.text = 'https://api.openai.com/v1';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AstraScope.of(context);
    final palette = AstraPalette.of(context);
    final account =
        _accountId == null ? null : controller.repo.account(_accountId!);
    final models = account == null
        ? const <ModelInfo>[]
        : controller.modelsFor(account.id, enabledOnly: false);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.accountId == null && _accountId == null ? '添加模型服务' : '模型服务'),
        actions: [
          if (account != null)
            IconButton(
              tooltip: '删除服务',
              onPressed: _busy ? null : () => _delete(controller),
              icon: Icon(Icons.delete_outline, color: palette.danger),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilledButton(
              onPressed: _busy ? null : () => _save(controller, quiet: false),
              child: const Text('保存'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(22, 10, 22, 40),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _fieldLabel('名称'),
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(hintText: '例如 OpenAI、DeepSeek'),
                ),
                const SizedBox(height: 16),
                _fieldLabel('接口格式'),
                const SizedBox(height: 6),
                SegmentedButton<ProviderFormat>(
                  segments: const [
                    ButtonSegment(
                      value: ProviderFormat.openai,
                      label: Text('OpenAI 兼容'),
                      icon: Icon(Icons.bolt_outlined, size: 16),
                    ),
                    ButtonSegment(
                      value: ProviderFormat.anthropic,
                      label: Text('Anthropic'),
                      icon: Icon(Icons.auto_awesome_outlined, size: 16),
                    ),
                  ],
                  selected: {_format},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) {
                    setState(() {
                      _format = selection.first;
                      if (_baseUrl.text.isEmpty ||
                          _baseUrl.text == 'https://api.openai.com/v1' ||
                          _baseUrl.text == 'https://api.anthropic.com') {
                        _baseUrl.text = _format == ProviderFormat.anthropic
                            ? 'https://api.anthropic.com'
                            : 'https://api.openai.com/v1';
                      }
                    });
                  },
                ),
                const SizedBox(height: 16),
                _fieldLabel('Base URL'),
                TextField(
                  controller: _baseUrl,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    hintText: _format == ProviderFormat.anthropic
                        ? 'https://api.anthropic.com'
                        : 'https://api.openai.com/v1',
                  ),
                ),
                const SizedBox(height: 16),
                _fieldLabel('API Key（只保存在本机）'),
                TextField(
                  controller: _apiKey,
                  obscureText: true,
                  decoration: InputDecoration(
                    hintText: account != null && controller.hasAccountKey(account.id)
                        ? '已保存，留空保持原 Key'
                        : '粘贴 API Key',
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _busy
                          ? null
                          : () async {
                              final id = await _save(controller, quiet: true);
                              if (id == null) return;
                              setState(() => _busy = true);
                              try {
                                final count = await controller.fetchModels(id);
                                if (!mounted) return;
                                showAppSnack(context, '已获取 $count 个模型');
                              } catch (error) {
                                if (!mounted) return;
                                showAppSnack(context, '$error');
                              } finally {
                                if (mounted) setState(() => _busy = false);
                              }
                            },
                      icon: const Icon(Icons.sync, size: 17),
                      label: const Text('拉取模型'),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '需要先保存有效的 API Key',
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                    if (_busy) ...[
                      const SizedBox(width: 14),
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 26),
                SectionTitle(
                  title: '模型',
                  subtitle: '启用多个模型后，可在对话顶部随时切换',
                  trailing: account == null
                      ? null
                      : TextButton.icon(
                          onPressed: _busy ? null : () => _addManualModel(controller),
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('手动添加'),
                        ),
                ),
                const SizedBox(height: 10),
                if (account == null)
                  Text(
                    '先保存服务，然后拉取或手动添加模型。',
                    style: TextStyle(color: palette.muted),
                  )
                else if (models.isEmpty)
                  AstraSurface(
                    child: Row(
                      children: [
                        Icon(Icons.inventory_2_outlined, color: palette.muted),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '还没有模型。点击「拉取模型」，或手动添加模型 ID。',
                            style: TextStyle(color: palette.muted, height: 1.5),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  ...models.map(
                    (model) => _ModelTile(
                      model: model,
                      isDefault:
                          account.defaultModelId == model.modelId,
                      onToggle: (value) => controller.updateModel(
                        model,
                        enabled: value,
                      ),
                      onDefault: () =>
                          controller.setDefaultModel(account.id, model.modelId),
                      onOptions: () => _editModel(controller, model),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  _format == ProviderFormat.anthropic
                      ? 'Anthropic 会请求 adaptive thinking 摘要，遇不支持会自动降级。'
                      : '图片会作为 OpenAI content parts 发送；不支持视觉的模型可能报错。',
                  style: TextStyle(color: palette.muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fieldLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      );

  Future<String?> _save(
    AstraController controller, {
    required bool quiet,
  }) async {
    setState(() => _busy = true);
    try {
      final account = await controller.saveAccount(
        id: _accountId,
        name: _name.text,
        format: _format,
        baseUrl: _baseUrl.text,
        apiKey: _apiKey.text,
      );
      _accountId = account.id;
      _apiKey.clear();
      if (!quiet && mounted) {
        showAppSnack(context, '服务已保存');
      }
      setState(() {});
      return account.id;
    } catch (error) {
      if (mounted) showAppSnack(context, '$error');
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(AstraController controller) async {
    final account =
        _accountId == null ? null : controller.repo.account(_accountId!);
    if (account == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除模型服务？'),
        content: Text(
          '将移除「${account.name}」及其模型配置。已有对话会保留，但将无法继续使用该服务。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AstraPalette.of(context).danger,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.deleteAccount(account.id);
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _addManualModel(AstraController controller) async {
    final id = TextEditingController();
    final label = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加模型'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: id,
              autofocus: true,
              decoration: const InputDecoration(hintText: '模型 ID，例如 gpt-4o-mini'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: label,
              decoration: const InputDecoration(
                hintText: '显示名称（可选）',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (result == true && _accountId != null) {
      try {
        await controller.addManualModel(
          accountId: _accountId!,
          modelId: id.text,
          displayName: label.text,
        );
      } catch (error) {
        if (mounted) showAppSnack(context, '$error');
      }
    }
    id.dispose();
    label.dispose();
  }

  Future<void> _editModel(
    AstraController controller,
    ModelInfo model,
  ) async {
    var vision = model.supportsVision;
    var tools = model.supportsTools;
    var reasoning = model.supportsReasoning;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(model.displayName, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                model.modelId,
                style: TextStyle(
                  color: AstraPalette.of(context).muted,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('支持图片输入'),
                value: vision,
                onChanged: (value) => setSheetState(() => vision = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('支持工具调用'),
                value: tools,
                onChanged: (value) => setSheetState(() => tools = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('支持思维链'),
                value: reasoning,
                onChanged: (value) => setSheetState(() => reasoning = value),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () async {
                    await controller.updateModel(
                      model,
                      vision: vision,
                      tools: tools,
                      reasoning: reasoning,
                    );
                    if (context.mounted) Navigator.of(context).maybePop();
                  },
                  child: const Text('完成'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.model,
    required this.isDefault,
    required this.onToggle,
    required this.onDefault,
    required this.onOptions,
  });

  final ModelInfo model;
  final bool isDefault;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDefault;
  final VoidCallback onOptions;

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    return AstraSurface(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        model.displayName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (isDefault) ...[
                      const SizedBox(width: 8),
                      Pill(
                        label: '默认',
                        color: palette.accent,
                        background: palette.accentSoft,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 5),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (model.supportsVision)
                      const Pill(label: '视觉', icon: Icons.image_outlined),
                    if (model.supportsTools)
                      const Pill(label: '工具', icon: Icons.build_outlined),
                    if (model.supportsReasoning)
                      const Pill(label: '推理', icon: Icons.psychology_outlined),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '设为默认',
            onPressed: isDefault ? null : onDefault,
            icon: Icon(
              isDefault ? Icons.star : Icons.star_border,
              size: 19,
              color: isDefault ? palette.warning : palette.muted,
            ),
          ),
          IconButton(
            tooltip: '能力与选项',
            onPressed: onOptions,
            icon: Icon(Icons.tune, size: 18, color: palette.muted),
          ),
          Switch(
            value: model.enabled,
            onChanged: onToggle,
          ),
        ],
      ),
    );
  }
}
