import 'package:flutter/material.dart';

import '../../data/models/models.dart';
import '../../state/astra_controller.dart';
import '../screens/provider_edit_screen.dart';
import '../theme.dart';
import 'common.dart';

Future<void> showModelPicker(
  BuildContext context,
  AstraController controller,
  Conversation conversation,
) async {
  final models = controller.modelsFor(conversation.accountId);
  if (models.isEmpty) {
    showAppSnack(context, '该服务没有启用的模型，请先在设置中添加模型。');
    return;
  }
  final selected = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      final palette = AstraPalette.of(context);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 4, 22, 10),
                child: Row(
                  children: [
                    Text(
                      '选择模型',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () {
                        final navigator = Navigator.of(context);
                        navigator.pop();
                        navigator.push(
                          MaterialPageRoute<void>(
                            builder: (_) => ProviderEditScreen(
                              accountId: conversation.accountId,
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.tune, size: 16),
                      label: const Text('管理'),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: palette.border),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 22),
                  itemCount: models.length,
                  itemBuilder: (context, index) {
                    final model = models[index];
                    final isSelected = model.modelId == conversation.modelId;
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                      leading: Icon(
                        isSelected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: isSelected ? palette.accent : palette.muted,
                        size: 19,
                      ),
                      title: Text(
                        model.displayName,
                        style: TextStyle(
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                      subtitle: Wrap(
                        spacing: 5,
                        children: [
                          if (model.supportsVision)
                            const Pill(label: '视觉'),
                          if (model.supportsTools)
                            const Pill(label: '工具'),
                          if (model.supportsReasoning)
                            const Pill(label: '推理'),
                        ],
                      ),
                      onTap: () => Navigator.of(context).pop(model.modelId),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (selected == null) return;
  await controller.setConversationModel(selected);
}
