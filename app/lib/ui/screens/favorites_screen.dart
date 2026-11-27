import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app.dart';
import '../theme.dart';
import '../widgets/common.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({
    super.key,
    required this.onJumpToTurn,
  });

  final void Function(String conversationId, String turnId) onJumpToTurn;

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  final _search = TextEditingController();

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
    final items = controller.favoriteTurns.where((entry) {
      if (query.isEmpty) return true;
      return entry.turn.text.toLowerCase().contains(query) ||
          entry.conversation.title.toLowerCase().contains(query);
    }).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 12),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: Row(
                children: [
                  Text(
                    '收藏的回答',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(width: 8),
                  if (controller.favoriteTurns.isNotEmpty)
                    Pill(
                      label: '${controller.favoriteTurns.length}',
                      color: palette.accent,
                      background: palette.accentSoft,
                    ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: '搜索收藏的回答或对话标题…',
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
        Divider(height: 1, color: palette.border),
        Expanded(
          child: items.isEmpty
              ? EmptyHint(
                  title: controller.favoriteTurns.isEmpty
                      ? '还没有收藏任何 AI 回答'
                      : '没有匹配的收藏',
                  body: controller.favoriteTurns.isEmpty
                      ? '在对话中点击任意 AI 回答下方的收藏图标，即可把优质回答集中保存在这里。'
                      : '试试更换搜索关键词。',
                  icon: Icons.bookmark_border_rounded,
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(22, 14, 22, 28),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final turn = item.turn;
                    final conversation = item.conversation;
                    final model = turn.modelId == null
                        ? null
                        : controller.repo.modelByRowId(turn.modelId!) ??
                            controller.repo.modelByModelId(
                              conversation.accountId,
                              turn.modelId!,
                            );
                    final timeText = _formatTime(
                      turn.favoriteAt ?? turn.createdAt,
                    );
                    return Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 880),
                        child: AstraSurface(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.fromLTRB(16, 14, 14, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.bookmark_rounded,
                                    size: 16,
                                    color: palette.warning,
                                  ),
                                  const SizedBox(width: 7),
                                  Expanded(
                                    child: Text(
                                      conversation.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13.5,
                                      ),
                                    ),
                                  ),
                                  if (model != null) ...[
                                    Pill(label: model.displayName),
                                    const SizedBox(width: 6),
                                  ],
                                  Text(
                                    timeText,
                                    style: TextStyle(
                                      color: palette.muted,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              MarkdownBody(
                                data: turn.text.trim().isEmpty
                                    ? turn.reasoning
                                    : turn.text,
                                selectable: true,
                                onTapLink: (text, href, title) {
                                  if (href == null) return;
                                  final uri = Uri.tryParse(href);
                                  if (uri == null) return;
                                  launchUrl(
                                    uri,
                                    mode: LaunchMode.externalApplication,
                                  );
                                },
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton.icon(
                                    onPressed: () async {
                                      final content = turn.text.trim().isEmpty
                                          ? turn.reasoning
                                          : turn.text;
                                      await Clipboard.setData(
                                        ClipboardData(text: content),
                                      );
                                      if (context.mounted) {
                                        showAppSnack(context, '已复制到剪贴板');
                                      }
                                    },
                                    icon: const Icon(
                                      Icons.copy_rounded,
                                      size: 15,
                                    ),
                                    label: const Text('复制'),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => widget.onJumpToTurn(
                                      conversation.id,
                                      turn.id,
                                    ),
                                    icon: const Icon(
                                      Icons.open_in_new_rounded,
                                      size: 15,
                                    ),
                                    label: const Text('原对话'),
                                  ),
                                  TextButton.icon(
                                    onPressed: () =>
                                        controller.toggleFavoriteTurn(
                                      conversation.id,
                                      turn.id,
                                    ),
                                    icon: Icon(
                                      Icons.bookmark_remove_outlined,
                                      size: 16,
                                      color: palette.muted,
                                    ),
                                    label: Text(
                                      '取消收藏',
                                      style: TextStyle(color: palette.muted),
                                    ),
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
    );
  }
}

String _formatTime(String iso) {
  final time = DateTime.tryParse(iso)?.toLocal();
  if (time == null) return '';
  final m = time.month.toString().padLeft(2, '0');
  final d = time.day.toString().padLeft(2, '0');
  final hh = time.hour.toString().padLeft(2, '0');
  final mm = time.minute.toString().padLeft(2, '0');
  return '$m/$d $hh:$mm';
}
