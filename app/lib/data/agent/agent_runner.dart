import 'dart:async';

import '../memory/memory_service.dart';
import '../models/models.dart';
import '../providers/llm_client.dart';
import '../providers/provider_common.dart';
import '../tools/tool_registry.dart';

class AgentFailure implements Exception {
  AgentFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

class AgentRunner {
  AgentRunner({
    required this.client,
    required this.tools,
  });

  final LlmClient client;
  final ToolRegistry tools;
  static const maxToolRounds = 8;

  Future<void> run({
    required ProviderAccount account,
    required ModelInfo model,
    required String apiKey,
    required String conversationTitle,
    required List<Turn> turns,
    required Map<String, ImagePayload> images,
    required String systemPrompt,
    String summarizedThroughTurnId = '',
    required AppSettings settings,
    required ToolContext toolContext,
    required String Function() nextHlc,
    required Future<bool> Function(ToolApprovalRequest request) approve,
    required void Function() onUpdate,
    required Future<void> Function() onCheckpoint,
    required CancelToken cancelToken,
  }) async {
    final definitions =
        model.supportsTools ? tools.definitionsFor(settings) : <ToolDefinition>[];
    final definitionByName = {
      for (final definition in definitions) definition.name: definition,
    };

    var lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
    void touch() {
      final now = DateTime.now();
      if (now.difference(lastNotify).inMilliseconds >= 55) {
        lastNotify = now;
        onUpdate();
      }
    }

    Turn? assistant;
    try {
      for (var round = 0; round < maxToolRounds; round++) {
        if (cancelToken.isCancelled) throw CancelledException();
        final draft = Turn.assistant(
          conversationId: turns.isNotEmpty ? turns.first.conversationId : '',
          modelId: model.id,
          hlc: nextHlc(),
        );
        assistant = draft;
        turns.add(draft);
        onUpdate();

        final contextTurns = summarizedThroughTurnId.isEmpty
            ? turns
            : MemoryService.sliceTurnsFromSummary(
                turns,
                summarizedThroughTurnId,
              );
        final result = await client.streamChat(
          account: account,
          model: model,
          apiKey: apiKey,
          turns: contextTurns,
          images: images,
          systemPrompt: systemPrompt,
          settings: settings,
          tools: definitions,
          cancelToken: cancelToken,
          callbacks: StreamCallbacks(
            onText: (text) {
              _appendBlock(draft, 'text', text);
              touch();
            },
            onReasoning: (text) {
              _appendBlock(draft, 'reasoning', text);
              touch();
            },
          ),
        );

        draft.status = TurnStatus.complete;
        draft.providerRaw = result.providerRaw;
        if (result.toolCalls.isEmpty) {
          onUpdate();
          await onCheckpoint();
          return;
        }

        final toolCalls = <ToolCall>[];
        for (final call in result.toolCalls) {
          draft.blocks.add(
            ContentBlock.toolCall(
              id: call.id,
              name: call.name,
              argumentsJson: call.argumentsJson,
            ),
          );
          toolCalls.add(call);
        }
        draft.status = TurnStatus.awaitingTools;
        onUpdate();
        await onCheckpoint();

        final results = <ContentBlock>[];
        for (final call in toolCalls) {
          if (cancelToken.isCancelled) {
            draft.status = TurnStatus.stopped;
            onUpdate();
            await onCheckpoint();
            return;
          }
          final block = draft.blocks.firstWhere(
            (item) => item.type == 'toolCall' && item.toolCallId == call.id,
            orElse: () => ContentBlock.toolCall(
              id: call.id,
              name: call.name,
              argumentsJson: call.argumentsJson,
            ),
          );
          final definition = definitionByName[call.name];
          if (definition == null) {
            block.toolStatus = ToolCallStatus.error;
            results.add(
              ContentBlock.toolResult(
                toolCallId: call.id,
                result: '该工具未启用或不存在。',
                isError: true,
              ),
            );
            continue;
          }
          var approved = true;
          if (definition.requiresApproval) {
            approved = await approve(
              ToolApprovalRequest(
                call: call,
                definition: definition,
                conversationTitle: conversationTitle,
              ),
            );
          }
          if (!approved) {
            block.toolStatus = ToolCallStatus.rejected;
            results.add(
              ContentBlock.toolResult(
                toolCallId: call.id,
                result: '用户拒绝执行。',
                isError: true,
              ),
            );
            onUpdate();
            continue;
          }
          block.toolStatus = ToolCallStatus.running;
          onUpdate();
          final executed = await tools.execute(call, toolContext);
          block.toolStatus =
              executed.isError ? ToolCallStatus.error : ToolCallStatus.success;
          results.add(
            ContentBlock.toolResult(
              toolCallId: call.id,
              result: executed.content,
              isError: executed.isError,
            ),
          );
          onUpdate();
        }
        if (cancelToken.isCancelled) {
          draft.status = TurnStatus.stopped;
          onUpdate();
          await onCheckpoint();
          return;
        }
        final toolTurn = Turn.tool(
          conversationId: draft.conversationId,
          results: results,
          hlc: nextHlc(),
        );
        turns.add(toolTurn);
        onUpdate();
        await onCheckpoint();
      }

      if (assistant != null) {
        assistant.blocks.add(
          ContentBlock.error('已达到工具调用轮数上限，已停止继续执行。'),
        );
        assistant.status = TurnStatus.error;
        onUpdate();
        await onCheckpoint();
      }
    } on CancelledException {
      if (assistant != null) {
        assistant.status = TurnStatus.stopped;
      }
      onUpdate();
      await onCheckpoint();
    } on ProviderException catch (error) {
      if (assistant != null) {
        assistant.blocks.add(ContentBlock.error(error.message));
        assistant.status = TurnStatus.error;
      }
      onUpdate();
      await onCheckpoint();
      throw AgentFailure(error.message);
    } on AgentFailure {
      rethrow;
    } catch (error) {
      final message = error is TimeoutException
          ? '请求超时。'
          : '对话失败：$error';
      if (assistant != null) {
        assistant.blocks.add(ContentBlock.error(message));
        assistant.status = TurnStatus.error;
      }
      onUpdate();
      await onCheckpoint();
      throw AgentFailure(message);
    }
  }

  void _appendBlock(Turn turn, String type, String text) {
    if (text.isEmpty) return;
    ContentBlock? existing;
    for (final block in turn.blocks) {
      if (block.type == type) {
        existing = block;
        break;
      }
    }
    if (existing == null) {
      turn.blocks.add(
        type == 'text'
            ? ContentBlock.text(text)
            : ContentBlock.reasoning(text),
      );
    } else {
      existing.text = (existing.text ?? '') + text;
    }
  }
}
