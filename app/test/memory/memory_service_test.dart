import 'dart:convert';

import 'package:astra_gui/data/memory/memory_service.dart';
import 'package:astra_gui/data/models/models.dart';
import 'package:astra_gui/data/providers/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ProviderAccount _account() => ProviderAccount(
      id: 'acc-1',
      name: 'OpenAI',
      format: ProviderFormat.openai,
      baseUrl: 'https://example.test/v1',
      defaultModelId: 'gpt-4o-mini',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      hlc: '1:0:a',
    );

ModelInfo _model() => ModelInfo(
      id: 'm-1',
      accountId: 'acc-1',
      modelId: 'gpt-4o-mini',
      displayName: 'GPT-4o Mini',
      enabled: true,
      supportsVision: false,
      supportsTools: true,
      supportsReasoning: false,
      source: 'manual',
      updatedAt: '2026-01-01T00:00:00Z',
      hlc: '1:0:a',
    );

Turn _turn(
  String id,
  TurnRole role,
  String text, {
  bool favorite = false,
  String? favoriteAt,
}) =>
    Turn(
      id: id,
      conversationId: 'chat-1',
      role: role,
      blocks: role == TurnRole.tool
          ? [ContentBlock.toolResult(toolCallId: 'call_1', result: text)]
          : [ContentBlock.text(text)],
      createdAt: '2026-01-01T00:00:00Z',
      hlc: '1:0:a',
      favorite: favorite,
      favoriteAt: favoriteAt,
    );

void main() {
  test('Turn favorite serialization round-trip', () {
    final original = _turn(
      't-1',
      TurnRole.assistant,
      'Useful answer',
      favorite: true,
      favoriteAt: '2026-02-01T12:00:00Z',
    );
    final decoded = Turn.fromJson(original.toJson());
    expect(decoded.favorite, isTrue);
    expect(decoded.favoriteAt, '2026-02-01T12:00:00Z');
  });

  test('MemoryEntry and Conversation summary serialization round-trip', () {
    final memory = MemoryEntry(
      id: 'mem-1',
      content: '使用中文回复',
      category: MemoryCategory.preference,
      sourceConversationId: 'chat-1',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      hlc: '2:0:a',
    );
    final restoredMem = MemoryEntry.fromJson(memory.toJson());
    expect(restoredMem.category, MemoryCategory.preference);
    expect(restoredMem.content, '使用中文回复');

    final conv = Conversation(
      id: 'chat-1',
      title: 'Test',
      accountId: 'acc-1',
      modelId: 'gpt-4o-mini',
      turns: [],
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      hlc: '3:0:a',
      contextSummary: '早期讨论了架构设计',
      summarizedThroughTurnId: 't-4',
      summaryUpdatedAt: '2026-01-02T00:00:00Z',
    );
    final restoredConv = Conversation.fromJson(conv.toJson());
    expect(restoredConv.contextSummary, '早期讨论了架构设计');
    expect(restoredConv.summarizedThroughTurnId, 't-4');
    expect(restoredConv.summaryUpdatedAt, '2026-01-02T00:00:00Z');
  });

  test('planConversationCompaction keeps tool pairs intact', () {
    final turns = [
      _turn('t1', TurnRole.user, 'u1'),
      _turn('t2', TurnRole.assistant, 'a1'),
      _turn('t3', TurnRole.user, 'u2'),
      Turn(
        id: 't4',
        conversationId: 'chat-1',
        role: TurnRole.assistant,
        blocks: [
          ContentBlock.toolCall(
            id: 'call_1',
            name: 'web_search',
            argumentsJson: '{"query":"astra"}',
          ),
        ],
        createdAt: '2026-01-01T00:00:00Z',
        hlc: '1:0:a',
      ),
      _turn('t5', TurnRole.tool, 'search result'),
      _turn('t6', TurnRole.assistant, 'a2'),
      _turn('t7', TurnRole.user, 'u3'),
      _turn('t8', TurnRole.assistant, 'a3'),
    ];
    final conv = Conversation(
      id: 'chat-1',
      title: 'T',
      accountId: 'acc-1',
      modelId: 'gpt-4o-mini',
      turns: turns,
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      hlc: '1:0:a',
    );

    final plan = MemoryService.planConversationCompaction(
      conv,
      triggerTurns: 8,
      keepRecentTurns: 4,
    );
    expect(plan, isNotNull);
    // cutEndExclusive would initially be 4 (t5, a tool turn), so it steps back
    // to keep the assistant tool_call (t4) paired with t5 on the unsummarized side.
    expect(plan!.lastSummarizedTurnId, 't3');
    expect(plan.turnsToSummarize.map((t) => t.id), ['t1', 't2', 't3']);
  });

  test('buildEffectiveContext injects memories and conversation summary', () {
    final conv = Conversation(
      id: 'chat-1',
      title: 'T',
      accountId: 'acc-1',
      modelId: 'gpt-4o-mini',
      turns: [
        _turn('t1', TurnRole.user, 'old question'),
        _turn('t2', TurnRole.assistant, 'old answer'),
        _turn('t3', TurnRole.user, 'new question'),
      ],
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      hlc: '1:0:a',
      contextSummary: '用户询问了旧问题',
      summarizedThroughTurnId: 't2',
      summaryUpdatedAt: '2026-01-01T01:00:00Z',
    );
    final settings = AppSettings.defaults(
      deviceId: 'dev-1',
      deviceName: 'Dev',
    );
    final memories = [
      MemoryEntry(
        id: 'mem-1',
        content: '偏好使用 Dart',
        category: MemoryCategory.preference,
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        hlc: '1:0:a',
      ),
    ];

    final ctx = MemoryService.buildEffectiveContext(
      conversation: conv,
      baseSystemPrompt: 'Base prompt',
      memories: memories,
      settings: settings,
    );
    expect(ctx.turns.map((t) => t.id), ['t3']);
    expect(ctx.systemPrompt, contains('Base prompt'));
    expect(ctx.systemPrompt, contains('[偏好] 偏好使用 Dart'));
    expect(ctx.systemPrompt, contains('用户询问了旧问题'));
  });

  test('shouldCompressMemories triggers on count, cycles, or age', () {
    final settings = AppSettings.defaults(
      deviceId: 'dev-1',
      deviceName: 'Dev',
    )..maxMemoryEntries = 3;
    final four = List.generate(
      4,
      (i) => MemoryEntry(
        id: 'm$i',
        content: 'item $i',
        category: MemoryCategory.general,
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        hlc: '1:0:a',
      ),
    );
    expect(
      MemoryService.shouldCompressMemories(
        activeMemories: four,
        settings: settings,
      ),
      isTrue,
    );

    settings
      ..maxMemoryEntries = 24
      ..memoryMaintenanceCycles = 3;
    expect(
      MemoryService.shouldCompressMemories(
        activeMemories: four,
        settings: settings,
      ),
      isTrue,
    );
  });

  test('compressMemories parses JSON wrapped in code fences', () async {
    final client = LlmClient(
      clientFactory: () => MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': '```json\n'
                      '[{"category":"project","content":"正在开发 Astra Flutter 客户端"}]\n'
                      '```',
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final service = MemoryService(client: client);
    final compressed = await service.compressMemories(
      account: _account(),
      model: _model(),
      apiKey: 'sk-test',
      activeMemories: [
        MemoryEntry(
          id: 'm1',
          content: '开发 Astra',
          category: MemoryCategory.project,
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          hlc: '1:0:a',
        ),
        MemoryEntry(
          id: 'm2',
          content: '使用 Flutter',
          category: MemoryCategory.project,
          createdAt: '2026-01-02T00:00:00Z',
          updatedAt: '2026-01-02T00:00:00Z',
          hlc: '2:0:a',
        ),
      ],
      settings: AppSettings.defaults(deviceId: 'd1', deviceName: 'D'),
    );
    expect(compressed.length, 1);
    expect(compressed.single.category, MemoryCategory.project);
    expect(compressed.single.content, '正在开发 Astra Flutter 客户端');
  });
}
