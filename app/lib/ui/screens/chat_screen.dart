import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/models/models.dart';
import '../../state/astra_controller.dart';
import '../theme.dart';
import '../widgets/approval_card.dart';
import '../widgets/chat_composer.dart';
import '../widgets/common.dart';
import '../widgets/message_view.dart';
import '../widgets/model_picker.dart';
import 'provider_edit_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.showBack,
    required this.onBack,
    required this.onDeleted,
  });

  final bool showBack;
  final VoidCallback onBack;
  final VoidCallback onDeleted;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _targetTurnKey = GlobalKey();
  bool _autoScroll = true;
  double _lastViewInsetsBottom = 0;
  int _lastTurnCount = 0;
  int _lastTailLength = 0;
  bool _summaryExpanded = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    if (bottom > _lastViewInsetsBottom && _autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
    _lastViewInsetsBottom = bottom;
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    _autoScroll =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 90;
  }

  @override
  Widget build(BuildContext context) {
    final controller = AstraScope.of(context);
    final conversation = controller.currentConversation;
    if (conversation == null) {
      return const SizedBox.shrink();
    }
    final account = controller.repo.account(conversation.accountId);
    final model = account == null
        ? null
        : controller.repo.modelByModelId(account.id, conversation.modelId);
    final turns = conversation.turns
        .where((turn) => !turn.deleted)
        .toList(growable: false);
    final palette = AstraPalette.of(context);
    final approval = controller.pendingApproval;
    final showKeyWarning =
        account != null && !controller.hasAccountKey(account.id);
    final targetTurnId = controller.scrollToTurnId;
    final tailLen = turns.isEmpty
        ? 0
        : turns.last.text.length +
            turns.last.reasoning.length +
            turns.last.blocks.length;

    if (targetTurnId != null &&
        turns.any((turn) => turn.id == targetTurnId)) {
      _autoScroll = false;
      final targetIndex = turns.indexWhere((turn) => turn.id == targetTurnId);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final targetContext = _targetTurnKey.currentContext;
        if (targetContext != null) {
          controller.clearScrollToTurn();
          Scrollable.ensureVisible(
            targetContext,
            duration: const Duration(milliseconds: 220),
            alignment: 0.15,
          );
        } else if (_scroll.hasClients && turns.isNotEmpty) {
          final estimated = (_scroll.position.maxScrollExtent *
                  (targetIndex / turns.length))
              .clamp(0.0, _scroll.position.maxScrollExtent);
          _scroll.jumpTo(estimated);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            controller.clearScrollToTurn();
            final resolvedContext = _targetTurnKey.currentContext;
            if (resolvedContext != null) {
              Scrollable.ensureVisible(
                resolvedContext,
                duration: const Duration(milliseconds: 180),
                alignment: 0.15,
              );
            }
          });
        } else {
          controller.clearScrollToTurn();
        }
      });
    } else if (turns.length != _lastTurnCount || tailLen != _lastTailLength) {
      _lastTurnCount = turns.length;
      _lastTailLength = tailLen;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_autoScroll || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }

    return Column(
      children: [
        _Header(
          conversation: conversation,
          accountName: account?.name ?? '服务已移除',
          modelName: model?.displayName ?? conversation.modelId,
          connected: controller.sync.connectedCount,
          showBack: widget.showBack,
          onBack: widget.onBack,
          onModel: () => showModelPicker(context, controller, conversation),
          onPrompt: () => _editPrompt(controller, conversation),
          onCompact: () => _compactNow(controller, conversation),
          onExtractMemory: () => _extractMemory(controller, conversation),
          onRename: () => _rename(controller, conversation),
          onDelete: () => _delete(controller, conversation),
        ),
        if (conversation.contextSummary.trim().isNotEmpty)
          _SummaryBanner(
            summary: conversation.contextSummary,
            expanded: _summaryExpanded,
            onToggle: () => setState(() => _summaryExpanded = !_summaryExpanded),
            onClear: () => controller.clearConversationSummary(conversation.id),
          ),
        if (showKeyWarning)
          Container(
            width: double.infinity,
            color: palette.warning.withValues(alpha: 0.09),
            padding: const EdgeInsets.fromLTRB(18, 8, 10, 8),
            child: Row(
              children: [
                Icon(Icons.key_off_outlined, size: 16, color: palette.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '该模型服务在此设备还没有 API Key。',
                    style: TextStyle(color: palette.warning, fontSize: 12.5),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ProviderEditScreen(
                          accountId: conversation.accountId,
                        ),
                      ),
                    );
                  },
                  child: const Text('配置'),
                ),
              ],
            ),
          ),
        Expanded(
          child: turns.isEmpty
              ? Center(
                  child: Text(
                    '发送第一条消息开始对话',
                    style: TextStyle(color: palette.muted),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 12),
                  itemCount: turns.length + (approval == null ? 0 : 1),
                  itemBuilder: (context, index) {
                    if (index >= turns.length) {
                      return ApprovalCard(
                        request: approval!,
                        onAllow: () => controller.resolveToolApproval(true),
                        onReject: () => controller.resolveToolApproval(false),
                      );
                    }
                    final turn = turns[index];
                    final isTarget = targetTurnId == turn.id;
                    return Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 860),
                        child: ChatTurnView(
                          key: isTarget ? _targetTurnKey : ValueKey(turn.id),
                          turn: turn,
                          conversationId: conversation.id,
                        ),
                      ),
                    );
                  },
                ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ChatComposer(conversationId: conversation.id),
        ),
      ],
    );
  }

  Future<void> _editPrompt(
    AstraController controller,
    Conversation conversation,
  ) async {
    final text = TextEditingController(text: conversation.systemPrompt);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('系统提示词'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: text,
                minLines: 4,
                maxLines: 10,
                decoration: const InputDecoration(
                  hintText: '只对这个对话生效；留空则使用全局默认',
                ),
              ),
              const SizedBox(height: 10),
              Text(
                controller.settings.defaultSystemPrompt.isEmpty
                    ? '全局默认提示词为空'
                    : '全局默认：${controller.settings.defaultSystemPrompt}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AstraPalette.of(context).muted,
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
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
    text.dispose();
    if (result == null) return;
    await controller.setConversationPrompt(result);
  }

  Future<void> _rename(
    AstraController controller,
    Conversation conversation,
  ) async {
    final text = TextEditingController(text: conversation.title);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名对话'),
        content: TextField(
          controller: text,
          autofocus: true,
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
    text.dispose();
    if (result == null) return;
    await controller.renameConversation(conversation.id, result);
  }

  Future<void> _compactNow(
    AstraController controller,
    Conversation conversation,
  ) async {
    try {
      final compacted = await controller.compactConversationNow(conversation.id);
      if (!mounted) return;
      showAppSnack(
        context,
        compacted ? '已将早期对话压缩为摘要' : '当前对话较短，暂不需要压缩',
      );
    } catch (error) {
      if (mounted) showAppSnack(context, '$error');
    }
  }

  Future<void> _extractMemory(
    AstraController controller,
    Conversation conversation,
  ) async {
    try {
      final count = await controller.extractMemoryNow(
        conversationId: conversation.id,
      );
      if (!mounted) return;
      showAppSnack(
        context,
        count > 0 ? '已提取 $count 条长期记忆' : '未发现新的长期记忆',
      );
    } catch (error) {
      if (mounted) showAppSnack(context, '$error');
    }
  }

  Future<void> _delete(
    AstraController controller,
    Conversation conversation,
  ) async {
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
    if (confirmed != true) return;
    await controller.deleteConversation(conversation.id);
    if (mounted) widget.onDeleted();
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.conversation,
    required this.accountName,
    required this.modelName,
    required this.connected,
    required this.showBack,
    required this.onBack,
    required this.onModel,
    required this.onPrompt,
    required this.onCompact,
    required this.onExtractMemory,
    required this.onRename,
    required this.onDelete,
  });

  final Conversation conversation;
  final String accountName;
  final String modelName;
  final int connected;
  final bool showBack;
  final VoidCallback onBack;
  final VoidCallback onModel;
  final VoidCallback onPrompt;
  final VoidCallback onCompact;
  final VoidCallback onExtractMemory;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(showBack ? 6 : 22, 12, 12, 12),
      decoration: BoxDecoration(
        color: palette.canvas,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          if (showBack)
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_rounded, size: 21),
              tooltip: '返回',
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conversation.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        accountName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: palette.muted, fontSize: 11.5),
                      ),
                    ),
                    if (connected > 0) ...[
                      const SizedBox(width: 8),
                      Icon(
                        Icons.cloud_done_outlined,
                        size: 13,
                        color: palette.accent,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '$connected',
                        style: TextStyle(
                          color: palette.accent,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          InkWell(
            onTap: onModel,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              constraints: BoxConstraints(maxWidth: showBack ? 145 : 230),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: palette.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.memory, size: 14, color: palette.accent),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      modelName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.ink,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.expand_more,
                    size: 15,
                    color: palette.muted,
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: PopupMenuButton<String>(
              tooltip: '对话选项',
              icon: Icon(Icons.more_horiz, color: palette.muted, size: 21),
              onSelected: (value) {
                if (value == 'prompt') onPrompt();
                if (value == 'compact') onCompact();
                if (value == 'memory') onExtractMemory();
                if (value == 'rename') onRename();
                if (value == 'delete') onDelete();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'prompt', child: Text('系统提示词')),
                PopupMenuItem(value: 'compact', child: Text('立即压缩上下文')),
                PopupMenuItem(value: 'memory', child: Text('提取长期记忆')),
                PopupMenuItem(value: 'rename', child: Text('重命名')),
                PopupMenuItem(value: 'delete', child: Text('删除对话')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryBanner extends StatelessWidget {
  const _SummaryBanner({
    required this.summary,
    required this.expanded,
    required this.onToggle,
    required this.onClear,
  });

  final String summary;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    return Container(
      width: double.infinity,
      color: palette.surfaceAlt.withValues(alpha: 0.75),
      padding: const EdgeInsets.fromLTRB(18, 6, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.compress, size: 14, color: palette.accent),
              const SizedBox(width: 6),
              Expanded(
                child: InkWell(
                  onTap: onToggle,
                  child: Text(
                    expanded ? '早期上下文压缩摘要（点击收起）' : '已启用早期上下文压缩摘要（点击查看）',
                    style: TextStyle(
                      color: palette.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: expanded ? '收起' : '展开',
                onPressed: onToggle,
                icon: Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: palette.muted,
                ),
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: '清除摘要',
                onPressed: onClear,
                icon: Icon(Icons.close, size: 15, color: palette.muted),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 10, 6),
              child: SelectableText(
                summary,
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
