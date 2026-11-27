import 'dart:convert';

import 'package:flutter/material.dart';

import '../../data/models/models.dart';
import '../theme.dart';

class ApprovalCard extends StatelessWidget {
  const ApprovalCard({
    super.key,
    required this.request,
    required this.onAllow,
    required this.onReject,
  });

  final ToolApprovalRequest request;
  final VoidCallback onAllow;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    final arguments = request.call.arguments();
    final preview = request.call.name == 'run_python'
        ? '${arguments['code'] ?? ''}'
        : request.call.name == 'run_shell'
            ? '${arguments['command'] ?? ''}'
            : const JsonEncoder.withIndent('  ').convert(arguments);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: Container(
          margin: const EdgeInsets.only(top: 10, bottom: 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.warning.withValues(alpha: 0.55)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.shield_outlined, color: palette.warning, size: 19),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '需要确认：${request.call.name}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    request.conversationTitle ?? '',
                    style: TextStyle(color: palette.muted, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                request.definition.description,
                style: TextStyle(color: palette.muted, fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 230),
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: palette.tool,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: palette.border),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    preview.length > 4000
                        ? '${preview.substring(0, 4000)}\n…'
                        : preview,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: onReject,
                    child: const Text('拒绝'),
                  ),
                  const SizedBox(width: 9),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: palette.warning,
                      foregroundColor: Colors.black87,
                    ),
                    onPressed: onAllow,
                    child: const Text('允许执行'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
