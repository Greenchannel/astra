import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/models/models.dart';
import '../../state/astra_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';

class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  final _search = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AstraScope.of(context);
    final palette = AstraPalette.of(context);
    final query = _search.text.trim().toLowerCase();
    final memories = controller.memories.where((item) {
      if (query.isEmpty) return true;
      return item.content.toLowerCase().contains(query) ||
          item.category.label.toLowerCase().contains(query);
    }).toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: Text('长期记忆 (${controller.memories.length})'),
        actions: [
          IconButton(
            tooltip: '新增记忆',
            onPressed: _busy ? null : () => _editDialog(controller),
            icon: const Icon(Icons.add),
          ),
          PopupMenuButton<String>(
            enabled: !_busy && !controller.memoryBusy,
            onSelected: (value) async {
              if (value == 'extract') await _extract(controller);
              if (value == 'compress') await _compress(controller);
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'extract',
                child: Text('从当前对话提取记忆'),
              ),
              PopupMenuItem(
                value: 'compress',
                child: Text('立即总结压缩记忆'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_busy || controller.memoryBusy)
            const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: '搜索记忆内容或分类…',
                    prefixIcon: const Icon(Icons.search, size: 19),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            onPressed: () {
                              _search.clear();
                              setState(() {});
                            },
                            icon: const Icon(Icons.close, size: 17),
                          ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: memories.isEmpty
                ? EmptyHint(
                    title: controller.memories.isEmpty
                        ? '还没有长期记忆'
                        : '没有匹配的记忆',
                    body: controller.memories.isEmpty
                        ? '对话开启长期记忆后，系统会定期自动提炼偏好与重要信息并压缩去重；也可以右上角手动新增。'
                        : '试试更换搜索关键词。',
                    icon: Icons.psychology_alt_outlined,
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(18, 6, 18, 28),
                    itemCount: memories.length,
                    itemBuilder: (context, index) {
                      final entry = memories[index];
                      return Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 860),
                          child: AstraSurface(
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Pill(
                                            label: entry.category.label,
                                            color: palette.accent,
                                            background: palette.accentSoft,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            _formatDate(entry.updatedAt),
                                            style: TextStyle(
                                              color: palette.muted,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      SelectableText(
                                        entry.content,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          height: 1.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  icon: Icon(
                                    Icons.more_horiz,
                                    color: palette.muted,
                                    size: 19,
                                  ),
                                  onSelected: (value) async {
                                    if (value == 'edit') {
                                      await _editDialog(
                                        controller,
                                        existing: entry,
                                      );
                                    } else if (value == 'delete') {
                                      await controller.deleteMemory(entry.id);
                                    }
                                  },
                                  itemBuilder: (context) => const [
                                    PopupMenuItem(
                                      value: 'edit',
                                      child: Text('编辑'),
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Text('删除'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _editDialog(
    AstraController controller, {
    MemoryEntry? existing,
  }) async {
    final text = TextEditingController(text: existing?.content ?? '');
    var category = existing?.category ?? MemoryCategory.general;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? '新增记忆' : '编辑记忆'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<MemoryCategory>(
                  value: category,
                  decoration: const InputDecoration(labelText: '分类'),
                  items: MemoryCategory.values
                      .map(
                        (item) => DropdownMenuItem(
                          value: item,
                          child: Text(item.label),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => category = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: text,
                  minLines: 3,
                  maxLines: 6,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '记忆内容',
                    hintText: '例如：回答代码问题时优先使用 Python 3.12',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved == true && text.text.trim().isNotEmpty) {
      if (existing == null) {
        await controller.addMemory(content: text.text, category: category);
      } else {
        await controller.updateMemory(
          existing,
          content: text.text,
          category: category,
        );
      }
    }
    text.dispose();
  }

  Future<void> _extract(AstraController controller) async {
    setState(() => _busy = true);
    try {
      final count = await controller.extractMemoryNow();
      if (mounted) {
        showAppSnack(
          context,
          count > 0 ? '已提取 $count 条新记忆' : '近期对话中没有新增可提取的记忆',
        );
      }
    } catch (error) {
      if (mounted) showAppSnack(context, '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _compress(AstraController controller) async {
    setState(() => _busy = true);
    try {
      final count = await controller.compressMemoriesNow();
      if (mounted) showAppSnack(context, '记忆已总结压缩为 $count 条');
    } catch (error) {
      if (mounted) showAppSnack(context, '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

String _formatDate(String iso) {
  final time = DateTime.tryParse(iso)?.toLocal();
  if (time == null) return '';
  final m = time.month.toString().padLeft(2, '0');
  final d = time.day.toString().padLeft(2, '0');
  final hh = time.hour.toString().padLeft(2, '0');
  final mm = time.minute.toString().padLeft(2, '0');
  return '$m/$d $hh:$mm';
}
