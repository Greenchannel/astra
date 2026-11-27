import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../data/attachments/attachment_service.dart';
import '../theme.dart';
import 'common.dart';

class ChatComposer extends StatefulWidget {
  const ChatComposer({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final List<PendingImage> _images = [];
  bool _picking = false;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AstraScope.of(context);
    final palette = AstraPalette.of(context);
    final conversation = controller.repo.conversation(widget.conversationId);
    if (conversation == null) return const SizedBox.shrink();
    final account = controller.repo.account(conversation.accountId);
    final model = account == null
        ? null
        : controller.repo.modelByModelId(account.id, conversation.modelId);
    final tools = <Widget>[];
    if (controller.settings.enableWebSearch) {
      tools.add(
        Tooltip(
          message: '联网搜索已启用',
          child: Icon(Icons.travel_explore, size: 17, color: palette.muted),
        ),
      );
    }
    if (controller.settings.enableCodeTools) {
      tools.add(
        Tooltip(
          message: '代码工具已启用',
          child: Icon(Icons.terminal, size: 17, color: palette.muted),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 16),
      child: Container(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: palette.border),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_images.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var index = 0; index < _images.length; index++)
                      _PendingThumb(
                        image: _images[index],
                        onRemove: () {
                          setState(() => _images.removeAt(index));
                        },
                      ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: '添加图片',
                  onPressed: _picking ? null : _pickImages,
                  icon: _picking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_photo_alternate_outlined, size: 21),
                ),
                Expanded(
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.enter, control: true):
                          _send,
                      const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                          _send,
                      const SingleActivator(LogicalKeyboardKey.enter, alt: true):
                          _send,
                    },
                    child: TextField(
                      controller: _text,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      style: const TextStyle(fontSize: 14.5, height: 1.45),
                      decoration: const InputDecoration(
                        hintText: '发消息…（Ctrl+Enter 发送）',
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 9),
                        isDense: true,
                      ),
                    ),
                  ),
                ),
                if (tools.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final tool in tools)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: tool,
                        ),
                    ],
                  ),
                ],
                const SizedBox(width: 6),
                IconButton.filled(
                  tooltip: controller.generating ? '停止生成' : '发送',
                  onPressed: controller.generating ? _stop : _send,
                  style: IconButton.styleFrom(
                    backgroundColor: controller.generating
                        ? palette.danger.withValues(alpha: 0.12)
                        : palette.accent,
                    foregroundColor: controller.generating
                        ? palette.danger
                        : Colors.white,
                    fixedSize: const Size(40, 40),
                  ),
                  icon: Icon(
                    controller.generating
                        ? Icons.stop_rounded
                        : Icons.arrow_upward_rounded,
                    size: 20,
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 2),
              child: Text(
                model == null
                    ? '当前没有可用模型'
                    : '${model.displayName} · ${controller.settings.showReasoning ? '思维链开' : '思维链关'}',
                style: TextStyle(color: palette.muted, fontSize: 10.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImages() async {
    final controller = AstraScope.of(context);
    setState(() => _picking = true);
    try {
      final images = await controller.pickImages();
      if (!mounted) return;
      setState(() {
        for (final image in images) {
          if (_images.length >= AttachmentService.maxImages) break;
          _images.add(image);
        }
      });
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _send() {
    final controller = AstraScope.of(context);
    if (controller.generating) return;
    final conversation = controller.repo.conversation(widget.conversationId);
    if (conversation == null) return;
    final account = controller.repo.account(conversation.accountId);
    if (account == null) {
      showAppSnack(context, '该模型服务已被删除。');
      return;
    }
    if (!controller.hasAccountKey(account.id)) {
      showAppSnack(context, '请先在设置中配置该服务的 API Key。');
      return;
    }
    if (controller.repo.modelByModelId(account.id, conversation.modelId) ==
        null) {
      showAppSnack(context, '当前没有可用模型，请先选择模型。');
      return;
    }
    final text = _text.text.trim();
    if (text.isEmpty && _images.isEmpty) return;
    final images = List<PendingImage>.from(_images);
    _text.clear();
    setState(() => _images.clear());
    unawaited(controller.sendMessage(text, images: images));
    _focus.requestFocus();
  }

  void _stop() {
    final controller = AstraScope.of(context);
    unawaited(controller.stopGeneration());
  }
}

class _PendingThumb extends StatelessWidget {
  const _PendingThumb({required this.image, required this.onRemove});

  final PendingImage image;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            image.thumbnail,
            width: 62,
            height: 62,
            fit: BoxFit.cover,
          ),
        ),
        Positioned(
          right: -6,
          top: -6,
          child: Material(
            color: palette.surface,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(Icons.close, size: 13, color: palette.muted),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
