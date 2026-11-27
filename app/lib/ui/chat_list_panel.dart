import 'package:flutter/material.dart';

import '../app.dart';
import '../data/models/models.dart';
import 'theme.dart';
import 'widgets/common.dart';

class ChatListPanel extends StatefulWidget {
  const ChatListPanel({
    super.key,
    required this.onOpenChat,
    required this.onAddProvider,
    this.showBrand = false,
  });

  final void Function(String conversationId) onOpenChat;
  final VoidCallback onAddProvider;
  final bool showBrand;

  @override
  State<ChatListPanel> createState() => _ChatListPanelState();
}

class _ChatListPanelState extends State<ChatListPanel> {
  String? _renameId;

  @override
  Widget build(BuildContext context) {
    final controller = AstraScope.of(context);
    final palette = AstraPalette.of(context);
    final conversations = controller.conversations;

    return Container(
      color: palette.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 12, 12),
            child: Row(
              children: [
                if (widget.showBrand) const BrandMark(compact: true),
                if (widget.showBrand) const SizedBox(width: 10),
                Text(
                  '对话',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                IconButton(
                  tooltip: '新对话',
                  onPressed: () => _newChat(),
                  icon: const Icon(Icons.add_comment_outlined, size: 21),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: palette.border),
          Expanded(
            child: conversations.isEmpty
                ? _EmptyList(
                    hasAccounts: controller.accounts.isNotEmpty,
                    onNew: () {
                    _newChat();
                  },
                    onAddProvider: widget.onAddProvider,
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 18),
                    itemCount: conversations.length,
                    itemBuilder: (context, index) {
                      final conversation = conversations[index];
                      return _ConversationTile(
                        conversation: conversation,
                        selected:
                            controller.currentConversationId == conversation.id,
                        controller: controller,
                        onTap: () {
                          controller.selectConversation(conversation.id);
                          widget.onOpenChat(conversation.id);
                        },
                        onRename: () => _rename(conversation),
                        onDelete: () => _delete(conversation),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _newChat() async {
    final controller = AstraScope.of(context);
    final accounts = controller.accounts;
    if (accounts.isEmpty) {
      widget.onAddProvider();
      return;
    }
    String? accountId;
    if (accounts.length > 1) {
      accountId = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 4, 22, 10),
                child: Text(
                  '选择模型服务',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (final account in accounts)
                ListTile(
                  leading: Icon(
                    account.format == ProviderFormat.anthropic
                        ? Icons.auto_awesome_outlined
                        : Icons.bolt_outlined,
                  ),
                  title: Text(account.name),
                  subtitle: Text(
                    controller
                        .modelsFor(account.id)
                        .map((model) => model.displayName)
                        .take(3)
                        .join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.of(context).pop(account.id),
                ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );
      if (!mounted || accountId == null) return;
    } else {
      accountId = accounts.first.id;
    }
    final conversation = controller.newConversation(accountId: accountId);
    if (conversation != null) {
      widget.onOpenChat(conversation.id);
    }
  }

  Future<void> _rename(Conversation conversation) async {
    if (_renameId != null) return;
    _renameId = conversation.id;
    final text = TextEditingController(text: conversation.title);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名对话'),
        content: TextField(
          controller: text,
          autofocus: true,
          decoration: const InputDecoration(hintText: '对话名称'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(text.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    _renameId = null;
    text.dispose();
    if (!mounted || name == null) return;
    await AstraScope.of(context).renameConversation(conversation.id, name);
  }

  Future<void> _delete(Conversation conversation) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除对话？'),
        content: Text('“${conversation.title}”及其消息会被删除。'),
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
    if (!mounted || confirmed != true) return;
    await AstraScope.of(context).deleteConversation(conversation.id);
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.selected,
    required this.controller,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final Conversation conversation;
  final bool selected;
  final dynamic controller;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    final model = controller.repo.modelByModelId(
      conversation.accountId,
      conversation.modelId,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? palette.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 6, 11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        conversation.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: palette.ink,
                        ),
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: '更多',
                      padding: EdgeInsets.zero,
                      iconSize: 17,
                      icon: Icon(Icons.more_horiz, color: palette.muted),
                      onSelected: (value) {
                        if (value == 'rename') onRename();
                        if (value == 'delete') onDelete();
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'rename', child: Text('重命名')),
                        PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  conversation.preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 12.2,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        model?.displayName ?? conversation.modelId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? palette.accent : palette.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      _relativeTime(conversation.updatedAt),
                      style: TextStyle(color: palette.muted, fontSize: 10.5),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyList extends StatelessWidget {
  const _EmptyList({
    required this.hasAccounts,
    required this.onNew,
    required this.onAddProvider,
  });

  final bool hasAccounts;
  final VoidCallback onNew;
  final VoidCallback onAddProvider;

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              hasAccounts ? '还没有对话' : '还没有模型服务',
              style: TextStyle(
                color: palette.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.tonal(
              onPressed: hasAccounts ? onNew : onAddProvider,
              child: Text(hasAccounts ? '开始新对话' : '添加模型服务'),
            ),
          ],
        ),
      ),
    );
  }
}

String _relativeTime(String iso) {
  final time = DateTime.tryParse(iso)?.toLocal();
  if (time == null) return '';
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分';
  if (diff.inDays < 1) return '${diff.inHours} 小时';
  if (diff.inDays < 7) return '${diff.inDays} 天';
  return '${time.month}/${time.day}';
}
