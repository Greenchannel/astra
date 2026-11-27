import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app.dart';
import '../../data/models/models.dart';
import '../screens/image_viewer_screen.dart';
import '../theme.dart';
import 'common.dart';

class ChatTurnView extends StatelessWidget {
  const ChatTurnView({
    super.key,
    required this.turn,
    required this.conversationId,
  });

  final Turn turn;
  final String conversationId;

  @override
  Widget build(BuildContext context) {
    switch (turn.role) {
      case TurnRole.user:
        return _UserTurn(turn: turn);
      case TurnRole.assistant:
        return _AssistantTurn(turn: turn, conversationId: conversationId);
      case TurnRole.tool:
        return _ToolTurn(turn: turn);
    }
  }
}

class _UserTurn extends StatelessWidget {
  const _UserTurn({required this.turn});

  final Turn turn;

  @override
  Widget build(BuildContext context) {
    final controller = AstraScope.of(context);
    final palette = AstraPalette.of(context);
    final imageWidgets = <Widget>[];
    for (final block in turn.images) {
      final attachment = controller.repo.attachment(block.attachmentId ?? '');
      imageWidgets.add(_AttachmentThumb(attachment: attachment));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
            decoration: BoxDecoration(
              color: palette.userBubble,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: palette.accent.withValues(alpha: 0.14),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (imageWidgets.isNotEmpty) ...[
                  Wrap(spacing: 8, runSpacing: 8, children: imageWidgets),
                  if (turn.text.isNotEmpty) const SizedBox(height: 9),
                ],
                if (turn.text.isNotEmpty)
                  SelectionArea(
                    child: Text(
                      turn.text,
                      style: TextStyle(
                        fontSize: 14.5,
                        height: 1.55,
                        color: palette.ink,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AttachmentThumb extends StatelessWidget {
  const _AttachmentThumb({required this.attachment});

  final Attachment? attachment;

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    final path = attachment?.localPath;
    final file = path == null ? null : File(path);
    final exists = file != null && file.existsSync();
    return GestureDetector(
      onTap: exists
          ? () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ImageViewerScreen(
                    image: FileImage(file),
                    title: attachment?.fileName ?? '图片',
                  ),
                ),
              );
            }
          : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: exists
            ? Image.file(
                file,
                width: 150,
                height: 150,
                fit: BoxFit.cover,
                cacheWidth: 320,
              )
            : Container(
                width: 150,
                height: 150,
                color: palette.surfaceAlt,
                alignment: Alignment.center,
                child: Icon(
                  Icons.broken_image_outlined,
                  color: palette.muted,
                  size: 26,
                ),
              ),
      ),
    );
  }
}

class _AssistantTurn extends StatelessWidget {
  const _AssistantTurn({required this.turn, required this.conversationId});

  final Turn turn;
  final String conversationId;

  @override
  Widget build(BuildContext context) {
    final controller = AstraScope.of(context);
    final palette = AstraPalette.of(context);
    final showReasoning = controller.settings.showReasoning;
    final children = <Widget>[];

    if (showReasoning && turn.reasoning.trim().isNotEmpty) {
      children.add(
        _ReasoningPanel(
          text: turn.reasoning,
          streaming: turn.status == TurnStatus.streaming,
        ),
      );
      children.add(const SizedBox(height: 10));
    }

    for (final block in turn.blocks) {
      if (block.type == 'toolCall') {
        children.add(_ToolCallCard(block: block));
        children.add(const SizedBox(height: 8));
      } else if (block.type == 'error') {
        children.add(_ErrorPanel(message: block.text ?? '未知错误'));
        children.add(const SizedBox(height: 8));
      }
    }

    if (turn.text.trim().isNotEmpty) {
      children.add(
        MarkdownBody(
          data: turn.text,
          selectable: true,
          onTapLink: (text, href, title) {
            if (href == null) return;
            final uri = Uri.tryParse(href);
            if (uri == null) return;
            unawaited(
              launchUrl(uri, mode: LaunchMode.externalApplication)
                  .then<void>((_) {}),
            );
          },
          styleSheet: _markdownStyle(context, palette),
        ),
      );
    }

    if (turn.status == TurnStatus.streaming) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 1.7,
                  color: palette.accent,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                turn.text.isEmpty && turn.reasoning.isEmpty
                    ? '正在连接…'
                    : turn.text.isEmpty
                        ? '思考中…'
                        : '正在生成…',
                style: TextStyle(color: palette.muted, fontSize: 11.5),
              ),
            ],
          ),
        ),
      );
    } else if (turn.status == TurnStatus.awaitingTools) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Pill(
            label: '等待工具确认',
            icon: Icons.shield_outlined,
            color: palette.warning,
            background: palette.warning.withValues(alpha: 0.1),
          ),
        ),
      );
    } else if (turn.status == TurnStatus.stopped) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '已停止',
            style: TextStyle(color: palette.muted, fontSize: 11.5),
          ),
        ),
      );
    }

    final copyText = turn.text.trim().isNotEmpty
        ? turn.text
        : turn.reasoning.trim();
    if (turn.status != TurnStatus.streaming && copyText.isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TurnActionButton(
                icon: Icons.copy_rounded,
                label: '复制',
                color: palette.muted,
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: copyText));
                  if (context.mounted) {
                    showAppSnack(context, '已复制到剪贴板');
                  }
                },
              ),
              const SizedBox(width: 6),
              _TurnActionButton(
                icon: turn.favorite
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                label: turn.favorite ? '已收藏' : '收藏',
                color: turn.favorite ? palette.warning : palette.muted,
                onTap: () => controller.toggleFavoriteTurn(
                  conversationId,
                  turn.id,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.only(left: 13),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: palette.accent.withValues(alpha: 0.35),
              width: 2,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

class _ToolTurn extends StatelessWidget {
  const _ToolTurn({required this.turn});

  final Turn turn;

  @override
  Widget build(BuildContext context) {
    if (turn.toolResults.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          for (final block in turn.toolResults)
            _ToolResultCard(block: block),
        ],
      ),
    );
  }
}

class _ReasoningPanel extends StatefulWidget {
  const _ReasoningPanel({required this.text, required this.streaming});

  final String text;
  final bool streaming;

  @override
  State<_ReasoningPanel> createState() => _ReasoningPanelState();
}

class _ReasoningPanelState extends State<_ReasoningPanel> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: palette.surfaceAlt.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.psychology_outlined,
                    size: 15,
                    color: palette.muted,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    widget.streaming ? '思考中' : '思考过程',
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 17,
                    color: palette.muted,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 11),
              child: SelectionArea(
                child: Text(
                  widget.text,
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 12.5,
                    height: 1.55,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ToolCallCard extends StatelessWidget {
  const _ToolCallCard({required this.block});

  final ContentBlock block;

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    final status = block.toolStatus;
    final (label, color) = switch (status) {
      ToolCallStatus.pending => ('待确认', palette.warning),
      ToolCallStatus.running => ('执行中', palette.accent),
      ToolCallStatus.success => ('完成', palette.accent),
      ToolCallStatus.error => ('失败', palette.danger),
      ToolCallStatus.rejected => ('已拒绝', palette.muted),
    };
    final args = _prettyJson(block.argumentsJson ?? '{}');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
      decoration: BoxDecoration(
        color: palette.tool,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.build_outlined, size: 15, color: palette.muted),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '工具调用 · ${block.toolName ?? 'unknown'}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Pill(label: label, color: color),
            ],
          ),
          const SizedBox(height: 7),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 150),
            child: SingleChildScrollView(
              child: SelectableText(
                args.length > 1200 ? '${args.substring(0, 1200)}\n…' : args,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11.5,
                  height: 1.45,
                  color: palette.muted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolResultCard extends StatelessWidget {
  const _ToolResultCard({required this.block});

  final ContentBlock block;

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    final result = block.result ?? '';
    final isError = block.isError;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: palette.tool,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isError
              ? palette.danger.withValues(alpha: 0.4)
              : palette.border,
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 17,
            color: isError ? palette.danger : palette.accent,
          ),
          title: Text(
            '工具结果',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isError ? palette.danger : palette.ink,
            ),
          ),
          subtitle: Text(
            result.replaceAll('\n', ' ').trim(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: palette.muted, fontSize: 11),
          ),
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: SingleChildScrollView(
                child: SelectableText(
                  result.isEmpty ? '(empty)' : result,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    height: 1.45,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: palette.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.danger.withValues(alpha: 0.3)),
      ),
      child: SelectableText(
        message,
        style: TextStyle(
          color: palette.danger,
          fontSize: 12.5,
          height: 1.5,
        ),
      ),
    );
  }
}

MarkdownStyleSheet _markdownStyle(
  BuildContext context,
  AstraPalette palette,
) {
  final theme = Theme.of(context);
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: theme.textTheme.bodyLarge?.copyWith(
      fontSize: 14.8,
      height: 1.6,
      color: palette.ink,
    ),
    code: TextStyle(
      fontFamily: 'monospace',
      fontSize: 12.8,
      backgroundColor: palette.surfaceAlt,
      color: palette.ink,
    ),
    codeblockPadding: const EdgeInsets.all(12),
    codeblockDecoration: BoxDecoration(
      color: palette.surfaceAlt,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: palette.border),
    ),
    blockSpacing: 10,
    a: TextStyle(color: palette.accent, decoration: TextDecoration.underline),
    h1: theme.textTheme.titleLarge?.copyWith(fontSize: 20, color: palette.ink),
    h2: theme.textTheme.titleLarge?.copyWith(fontSize: 17, color: palette.ink),
    h3: theme.textTheme.titleMedium?.copyWith(color: palette.ink),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: palette.border, width: 3)),
    ),
  );
}

String _prettyJson(String source) {
  try {
    final decoded = jsonDecode(source);
    return const JsonEncoder.withIndent('  ').convert(decoded);
  } catch (_) {
    return source;
  }
}

class _TurnActionButton extends StatelessWidget {
  const _TurnActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
