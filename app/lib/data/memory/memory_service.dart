import 'dart:convert';

import '../../util/ids.dart';
import '../../util/json.dart';
import '../models/models.dart';
import '../providers/llm_client.dart';

class EffectiveContext {
  const EffectiveContext({
    required this.turns,
    required this.systemPrompt,
  });

  final List<Turn> turns;
  final String systemPrompt;
}

class CompactionPlan {
  const CompactionPlan({
    required this.turnsToSummarize,
    required this.lastSummarizedTurnId,
  });

  final List<Turn> turnsToSummarize;
  final String lastSummarizedTurnId;
}

class ExtractedMemoryDraft {
  const ExtractedMemoryDraft({
    required this.category,
    required this.content,
  });

  final MemoryCategory category;
  final String content;
}

class MemoryService {
  MemoryService({required LlmClient client}) : _client = client;

  final LlmClient _client;

  static const int maxAutoSummaryCharsTrigger = 24000;
  static const int periodicCompressionCycles = 3;
  static const Duration periodicCompressionInterval = Duration(days: 3);

  /// Returns non-deleted turns after [summarizedThroughTurnId], preserving
  /// assistant/tool turn pairing.
  static List<Turn> sliceTurnsFromSummary(
    List<Turn> turns,
    String summarizedThroughTurnId,
  ) {
    final activeTurns =
        turns.where((turn) => !turn.deleted).toList(growable: false);
    if (summarizedThroughTurnId.isEmpty) return activeTurns;
    final cutIndex = activeTurns.indexWhere(
      (turn) => turn.id == summarizedThroughTurnId,
    );
    if (cutIndex < 0 || cutIndex >= activeTurns.length - 1) {
      return activeTurns;
    }
    var start = cutIndex + 1;
    // Never start sliced history on a tool turn without its preceding
    // assistant tool_call turn.
    while (start < activeTurns.length &&
        activeTurns[start].role == TurnRole.tool) {
      start++;
    }
    if (start >= activeTurns.length) return activeTurns;
    return activeTurns.sublist(start);
  }

  /// Builds the sliced turn list and enriched system prompt using any
  /// conversation summary and active long-term memory entries.
  static EffectiveContext buildEffectiveContext({
    required Conversation conversation,
    required String baseSystemPrompt,
    required List<MemoryEntry> memories,
    required AppSettings settings,
  }) {
    final activeTurns = conversation.turns
        .where((turn) => !turn.deleted)
        .toList(growable: false);
    var slicedTurns = activeTurns;
    var usedSummary = false;

    if (conversation.contextSummary.trim().isNotEmpty &&
        conversation.summarizedThroughTurnId.isNotEmpty) {
      final candidate = sliceTurnsFromSummary(
        activeTurns,
        conversation.summarizedThroughTurnId,
      );
      if (candidate.length < activeTurns.length) {
        slicedTurns = candidate;
        usedSummary = true;
      }
    }

    final promptSections = <String>[];
    if (baseSystemPrompt.trim().isNotEmpty) {
      promptSections.add(baseSystemPrompt.trim());
    }
    if (settings.enableMemory && memories.isNotEmpty) {
      final buffer = StringBuffer()
        ..writeln('[长期记忆（跨对话背景参考；若与当前对话冲突，以当前对话为准）]');
      for (final item in memories.take(settings.maxMemoryEntries)) {
        final content = item.content.trim();
        if (content.isEmpty) continue;
        buffer.writeln('- [${item.category.label}] $content');
      }
      promptSections.add(buffer.toString().trim());
    }
    if (usedSummary) {
      promptSections.add(
        '[早期对话压缩摘要]\n${conversation.contextSummary.trim()}',
      );
    }

    return EffectiveContext(
      turns: slicedTurns,
      systemPrompt: promptSections.join('\n\n'),
    );
  }

  /// Computes which older turns should be summarized into `contextSummary`,
  /// returning `null` if thresholds are not yet reached.
  static CompactionPlan? planConversationCompaction(
    Conversation conversation, {
    required int triggerTurns,
    required int keepRecentTurns,
    bool force = false,
  }) {
    final active = conversation.turns
        .where((turn) => !turn.deleted)
        .toList(growable: false);
    if (active.length <= 2) return null;

    var startIndex = 0;
    if (conversation.summarizedThroughTurnId.isNotEmpty) {
      final existingIdx = active.indexWhere(
        (turn) => turn.id == conversation.summarizedThroughTurnId,
      );
      if (existingIdx >= 0) startIndex = existingIdx + 1;
    }

    final unsummarizedCount = active.length - startIndex;
    final minKeep = force ? 2 : keepRecentTurns.clamp(2, 50);
    if (unsummarizedCount <= minKeep) return null;

    if (!force) {
      var unsummarizedChars = 0;
      for (var i = startIndex; i < active.length; i++) {
        unsummarizedChars += active[i].text.length + active[i].reasoning.length;
        for (final result in active[i].toolResults) {
          unsummarizedChars += (result.result ?? '').length;
        }
      }
      if (unsummarizedCount < triggerTurns &&
          unsummarizedChars < maxAutoSummaryCharsTrigger) {
        return null;
      }
    }

    var cutEndExclusive = active.length - minKeep;
    // Ensure we don't cut right after an assistant tool_call turn while leaving
    // its tool_result turn on the unsummarized side.
    while (cutEndExclusive > startIndex &&
        cutEndExclusive < active.length &&
        active[cutEndExclusive].role == TurnRole.tool) {
      cutEndExclusive--;
    }
    if (cutEndExclusive <= startIndex) return null;

    final slice = active.sublist(startIndex, cutEndExclusive);
    if (slice.isEmpty) return null;
    return CompactionPlan(
      turnsToSummarize: slice,
      lastSummarizedTurnId: slice.last.id,
    );
  }

  /// Summarizes `plan.turnsToSummarize` merged with any existing summary.
  Future<String> summarizeTurns({
    required ProviderAccount account,
    required ModelInfo model,
    required String apiKey,
    required String existingSummary,
    required CompactionPlan plan,
    required AppSettings settings,
  }) async {
    final transcript = _formatTranscript(plan.turnsToSummarize);
    final prompt = StringBuffer();
    if (existingSummary.trim().isNotEmpty) {
      prompt.writeln('已有早期摘要：');
      prompt.writeln(existingSummary.trim());
      prompt.writeln();
    }
    prompt.writeln('新增历史对话片段：');
    prompt.writeln(transcript);
    prompt.writeln();
    prompt.writeln(
      '请把以上内容合并压缩为一份紧凑、准确的中文对话摘要（控制在 600 字以内，使用简洁条目），'
      '保留核心事实、用户要求、已做出的决定、关键代码/文件路径和未解决的问题，不要编造信息。',
    );

    final result = await _callSingleTurn(
      account: account,
      model: model,
      apiKey: apiKey,
      systemPrompt: '你是严谨的对话上下文压缩助手，只输出压缩后的摘要正文，不要额外寒暄。',
      userPrompt: prompt.toString(),
      settings: settings,
      maxTokens: 1024,
    );
    return result.trim();
  }

  /// Extracts durable user preferences/facts/project context from recent turns.
  Future<List<ExtractedMemoryDraft>> extractMemories({
    required ProviderAccount account,
    required ModelInfo model,
    required String apiKey,
    required List<Turn> recentTurns,
    required List<MemoryEntry> existingMemories,
    required AppSettings settings,
  }) async {
    final transcript = _formatTranscript(recentTurns, maxChars: 10000);
    if (transcript.trim().isEmpty) return const [];

    final existingBlock = existingMemories.isEmpty
        ? '（当前暂无长期记忆）'
        : existingMemories
            .map((item) => '- [${item.category.name}] ${item.content}')
            .join('\n');

    final userPrompt = '''
已有长期记忆：
$existingBlock

近期对话片段：
$transcript

请从近期对话中提取值得跨对话长期记住的用户信息（最多 3 条），例如：
- preference：语言/代码风格/工具/回答格式等长期偏好
- project：正在开发的项目背景、技术栈、路径、约束
- fact：用户明确提到的个人背景、设备环境或固定事实
- general：其他有长期价值的约定

忽略一次性的闲聊、临时搜索查询、已经存在于「已有长期记忆」中的重复内容。
严格只输出 JSON 数组，例如：
[{"category":"preference","content":"偏好使用简洁的中文回答"}]
如果没有需要新增的内容，输出 `[]`。
''';

    final raw = await _callSingleTurn(
      account: account,
      model: model,
      apiKey: apiKey,
      systemPrompt: '你是长期记忆提取器。只输出合法 JSON 数组，不要输出 Markdown 说明。',
      userPrompt: userPrompt,
      settings: settings,
      maxTokens: 768,
    );
    return parseMemoryDrafts(raw);
  }

  /// Determines whether periodic memory consolidation/compression should run.
  static bool shouldCompressMemories({
    required List<MemoryEntry> activeMemories,
    required AppSettings settings,
    DateTime? now,
  }) {
    if (activeMemories.length <= 1) return false;
    if (activeMemories.length > settings.maxMemoryEntries) return true;
    if (settings.memoryMaintenanceCycles >= periodicCompressionCycles &&
        activeMemories.length >= 4) {
      return true;
    }
    if (settings.lastMemoryMaintenanceAt.isNotEmpty &&
        activeMemories.length >= 6) {
      final last = DateTime.tryParse(settings.lastMemoryMaintenanceAt);
      if (last != null &&
          (now ?? DateTime.now().toUtc()).difference(last) >=
              periodicCompressionInterval) {
        return true;
      }
    }
    return false;
  }

  /// Consolidates, deduplicates, and compresses active memories via the LLM.
  Future<List<ExtractedMemoryDraft>> compressMemories({
    required ProviderAccount account,
    required ModelInfo model,
    required String apiKey,
    required List<MemoryEntry> activeMemories,
    required AppSettings settings,
  }) async {
    if (activeMemories.isEmpty) return const [];
    final listText = activeMemories
        .map(
          (item) =>
              '- (${item.updatedAt}) [${item.category.name}] ${item.content}',
        )
        .join('\n');

    final targetMax = settings.maxMemoryEntries.clamp(5, 100);
    final userPrompt = '''
以下是目前保存的 ${activeMemories.length} 条长期记忆（括号内为更新时间）：
$listText

请执行定期记忆总结与压缩：
1. 合并语义重复或高度相关的条目，保留完整但更精炼的表述；
2. 若前后信息存在冲突，以更新时间较新者为准；
3. 剔除过时、一次性或无长期价值的内容；
4. 压缩后总条数控制在 $targetMax 条以内，每条尽量简短清晰。

严格只输出 JSON 数组，格式：
[{"category":"preference|fact|project|general","content":"..."}]
''';

    final raw = await _callSingleTurn(
      account: account,
      model: model,
      apiKey: apiKey,
      systemPrompt: '你是长期记忆整理与压缩助手。只输出合法 JSON 数组，不要附加解释。',
      userPrompt: userPrompt,
      settings: settings,
      maxTokens: 1536,
    );
    return parseMemoryDrafts(raw);
  }

  static List<ExtractedMemoryDraft> parseMemoryDrafts(String raw) {
    var cleaned = raw.trim();
    if (cleaned.startsWith('```')) {
      final firstNewline = cleaned.indexOf('\n');
      if (firstNewline >= 0) {
        cleaned = cleaned.substring(firstNewline + 1);
      }
      final lastFence = cleaned.lastIndexOf('```');
      if (lastFence >= 0) {
        cleaned = cleaned.substring(0, lastFence);
      }
      cleaned = cleaned.trim();
    }
    final start = cleaned.indexOf('[');
    final end = cleaned.lastIndexOf(']');
    if (start < 0 || end <= start) return const [];
    final slice = cleaned.substring(start, end + 1);
    try {
      final decoded = jsonDecode(slice);
      if (decoded is! List) return const [];
      final drafts = <ExtractedMemoryDraft>[];
      final seen = <String>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        final content = asString(item['content']).trim();
        if (content.isEmpty) continue;
        final normalized = content.toLowerCase();
        if (!seen.add(normalized)) continue;
        drafts.add(
          ExtractedMemoryDraft(
            category: memoryCategoryFrom(asStringOrNull(item['category'])),
            content: content,
          ),
        );
      }
      return drafts;
    } catch (_) {
      return const [];
    }
  }

  Future<String> _callSingleTurn({
    required ProviderAccount account,
    required ModelInfo model,
    required String apiKey,
    required String systemPrompt,
    required String userPrompt,
    required AppSettings settings,
    required int maxTokens,
  }) async {
    final helperSettings = AppSettings(
      deviceId: settings.deviceId,
      deviceName: settings.deviceName,
      theme: settings.theme,
      defaultSystemPrompt: '',
      maxTokens: maxTokens,
      temperature: 0.2,
      showReasoning: false,
      enableCodeTools: false,
      enableShellTool: false,
      enableWebSearch: false,
      searchProvider: settings.searchProvider,
      searchResultCount: settings.searchResultCount,
      pythonPath: settings.pythonPath,
      hlc: settings.hlc,
    );
    final helperModel = ModelInfo(
      id: model.id,
      accountId: model.accountId,
      modelId: model.modelId,
      displayName: model.displayName,
      enabled: model.enabled,
      supportsVision: false,
      supportsTools: false,
      supportsReasoning: false,
      source: model.source,
      updatedAt: model.updatedAt,
      hlc: model.hlc,
    );
    final turn = Turn.user(
      conversationId: 'memory',
      blocks: [ContentBlock.text(userPrompt)],
      hlc: '0:0:memory',
    );
    final result = await _client.streamChat(
      account: account,
      model: helperModel,
      apiKey: apiKey,
      turns: [turn],
      images: const {},
      systemPrompt: systemPrompt,
      settings: helperSettings,
      tools: const [],
      cancelToken: CancelToken(),
      callbacks: StreamCallbacks(onText: (_) {}, onReasoning: (_) {}),
    );
    return result.text;
  }

  static String _formatTranscript(
    List<Turn> turns, {
    int maxChars = 14000,
  }) {
    final buffer = StringBuffer();
    for (final turn in turns) {
      if (turn.deleted) continue;
      if (turn.role == TurnRole.user) {
        final text = turn.text.trim();
        if (text.isNotEmpty) {
          buffer.writeln('用户: $text');
        }
      } else if (turn.role == TurnRole.assistant) {
        final text = turn.text.trim();
        if (text.isNotEmpty) {
          buffer.writeln('助手: $text');
        }
      } else if (turn.role == TurnRole.tool) {
        for (final block in turn.toolResults) {
          final out = (block.result ?? '').trim();
          if (out.isEmpty) continue;
          final compact = out.length > 400 ? '${out.substring(0, 400)}…' : out;
          buffer.writeln('工具输出: $compact');
        }
      }
      if (buffer.length >= maxChars) break;
    }
    final raw = buffer.toString();
    return raw.length > maxChars ? '${raw.substring(0, maxChars)}\n…' : raw;
  }
}

MemoryEntry newMemoryEntry({
  required String content,
  required MemoryCategory category,
  required String hlc,
  String sourceConversationId = '',
}) {
  final now = isoNow();
  return MemoryEntry(
    id: newId('mem'),
    content: content.trim(),
    category: category,
    sourceConversationId: sourceConversationId,
    createdAt: now,
    updatedAt: now,
    hlc: hlc,
  );
}
