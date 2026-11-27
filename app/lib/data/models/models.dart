import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../util/ids.dart';
import '../../util/json.dart';

enum ProviderFormat { openai, anthropic }

extension ProviderFormatLabel on ProviderFormat {
  String get label => this == ProviderFormat.anthropic
      ? 'Anthropic Messages'
      : 'OpenAI 兼容';

  String get protocolLabel => this == ProviderFormat.anthropic
      ? '/v1/messages'
      : '/chat/completions';
}

ProviderFormat providerFormatFrom(String? value) =>
    value == 'anthropic' ? ProviderFormat.anthropic : ProviderFormat.openai;

enum TurnRole { user, assistant, tool }

TurnRole turnRoleFrom(String? value) {
  switch (value) {
    case 'assistant':
      return TurnRole.assistant;
    case 'tool':
      return TurnRole.tool;
    default:
      return TurnRole.user;
  }
}

enum TurnStatus { streaming, complete, stopped, error, awaitingTools }

String turnStatusToWire(TurnStatus status) {
  switch (status) {
    case TurnStatus.streaming:
      return 'streaming';
    case TurnStatus.complete:
      return 'complete';
    case TurnStatus.stopped:
      return 'stopped';
    case TurnStatus.error:
      return 'error';
    case TurnStatus.awaitingTools:
      return 'awaiting_tools';
  }
}

TurnStatus turnStatusFrom(String? value) {
  switch (value) {
    case 'streaming':
      return TurnStatus.streaming;
    case 'stopped':
      return TurnStatus.stopped;
    case 'error':
      return TurnStatus.error;
    case 'awaiting_tools':
      return TurnStatus.awaitingTools;
    default:
      return TurnStatus.complete;
  }
}

enum ToolCallStatus { pending, running, success, error, rejected }

String toolCallStatusToWire(ToolCallStatus status) => status.name;

ToolCallStatus toolCallStatusFrom(String? value) {
  for (final status in ToolCallStatus.values) {
    if (status.name == value) return status;
  }
  return ToolCallStatus.pending;
}

enum SearchProvider { duckduckgo, tavily, brave }

String searchProviderToWire(SearchProvider provider) => provider.name;

SearchProvider searchProviderFrom(String? value) {
  for (final provider in SearchProvider.values) {
    if (provider.name == value) return provider;
  }
  return SearchProvider.duckduckgo;
}

extension SearchProviderLabel on SearchProvider {
  String get label {
    switch (this) {
      case SearchProvider.duckduckgo:
        return 'DuckDuckGo（免 Key）';
      case SearchProvider.tavily:
        return 'Tavily';
      case SearchProvider.brave:
        return 'Brave Search';
    }
  }
}

enum ThemePreference { system, light, dark }

ThemePreference themePreferenceFrom(String? value) {
  for (final pref in ThemePreference.values) {
    if (pref.name == value) return pref;
  }
  return ThemePreference.system;
}

// ---------------------------------------------------------------------------
// Tool and streaming types
// ---------------------------------------------------------------------------

class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.requiresApproval = true,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final bool requiresApproval;

  Map<String, dynamic> toOpenAi() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': inputSchema,
        },
      };

  Map<String, dynamic> toAnthropic() => {
        'name': name,
        'description': description,
        'input_schema': inputSchema,
      };
}

class ToolCall {
  const ToolCall({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });

  final String id;
  final String name;
  final String argumentsJson;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'arguments': argumentsJson,
      };

  factory ToolCall.fromJson(Map<String, dynamic> json) => ToolCall(
        id: asString(json['id']),
        name: asString(json['name']),
        argumentsJson: asString(json['arguments']),
      );

  Map<String, dynamic> arguments() {
    try {
      return asMap(jsonDecode(argumentsJson));
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}

class ToolExecutionResult {
  const ToolExecutionResult({required this.content, this.isError = false});

  final String content;
  final bool isError;

  factory ToolExecutionResult.error(String message) =>
      ToolExecutionResult(content: message, isError: true);

  Map<String, dynamic> toJson() => {'content': content, 'isError': isError};

  factory ToolExecutionResult.fromJson(Map<String, dynamic> json) =>
      ToolExecutionResult(
        content: asString(json['content']),
        isError: asBool(json['isError']),
      );
}

class ToolApprovalRequest {
  const ToolApprovalRequest({
    required this.call,
    required this.definition,
    this.conversationTitle,
  });

  final ToolCall call;
  final ToolDefinition definition;
  final String? conversationTitle;
}

class ImagePayload {
  const ImagePayload({required this.mimeType, required this.bytes});

  final String mimeType;
  final Uint8List bytes;
}

class ProviderResult {
  const ProviderResult({
    required this.text,
    required this.reasoning,
    required this.toolCalls,
    required this.providerRaw,
    required this.stopReason,
    this.usage,
  });

  final String text;
  final String reasoning;
  final List<ToolCall> toolCalls;
  final List<Map<String, dynamic>> providerRaw;
  final String stopReason;
  final Map<String, dynamic>? usage;
}

class StreamCallbacks {
  const StreamCallbacks({
    required this.onText,
    required this.onReasoning,
  });

  final void Function(String text) onText;
  final void Function(String text) onReasoning;
}

class CancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }
}

// ---------------------------------------------------------------------------
// Content blocks and turns
// ---------------------------------------------------------------------------

class ContentBlock {
  ContentBlock({
    required this.type,
    this.text,
    this.attachmentId,
    this.toolCallId,
    this.toolName,
    this.argumentsJson,
    this.toolStatus = ToolCallStatus.pending,
    this.result,
    this.isError = false,
    this.raw,
  });

  factory ContentBlock.text(String text) =>
      ContentBlock(type: 'text', text: text);

  factory ContentBlock.reasoning(String text, {Map<String, dynamic>? raw}) =>
      ContentBlock(type: 'reasoning', text: text, raw: raw);

  factory ContentBlock.image(String attachmentId) =>
      ContentBlock(type: 'image', attachmentId: attachmentId);

  factory ContentBlock.toolCall({
    required String id,
    required String name,
    required String argumentsJson,
  }) =>
      ContentBlock(
        type: 'toolCall',
        toolCallId: id,
        toolName: name,
        argumentsJson: argumentsJson,
      );

  factory ContentBlock.toolResult({
    required String toolCallId,
    required String result,
    bool isError = false,
  }) =>
      ContentBlock(
        type: 'toolResult',
        toolCallId: toolCallId,
        result: result,
        isError: isError,
      );

  factory ContentBlock.error(String message) =>
      ContentBlock(type: 'error', text: message);

  /// text | reasoning | image | toolCall | toolResult | error
  final String type;
  String? text;
  String? attachmentId;
  String? toolCallId;
  String? toolName;
  String? argumentsJson;
  ToolCallStatus toolStatus;
  String? result;
  bool isError;
  Map<String, dynamic>? raw;

  Map<String, dynamic> toJson() => {
        'type': type,
        if (text != null) 'text': text,
        if (attachmentId != null) 'attachmentId': attachmentId,
        if (toolCallId != null) 'toolCallId': toolCallId,
        if (toolName != null) 'toolName': toolName,
        if (argumentsJson != null) 'arguments': argumentsJson,
        'toolStatus': toolCallStatusToWire(toolStatus),
        if (result != null) 'result': result,
        if (isError) 'isError': true,
        if (raw != null) 'raw': raw,
      };

  factory ContentBlock.fromJson(Map<String, dynamic> json) => ContentBlock(
        type: asString(json['type'], 'text'),
        text: asStringOrNull(json['text']),
        attachmentId: asStringOrNull(json['attachmentId']),
        toolCallId: asStringOrNull(json['toolCallId']),
        toolName: asStringOrNull(json['toolName']),
        argumentsJson: asStringOrNull(json['arguments']),
        toolStatus: toolCallStatusFrom(asStringOrNull(json['toolStatus'])),
        result: asStringOrNull(json['result']),
        isError: asBool(json['isError']),
        raw: json['raw'] is Map ? asMap(json['raw']) : null,
      );
}

class Turn {
  Turn({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.blocks,
    required this.createdAt,
    required this.hlc,
    this.status = TurnStatus.complete,
    this.modelId,
    this.providerRaw = const [],
    this.favorite = false,
    this.favoriteAt,
    this.deleted = false,
  });

  final String id;
  final String conversationId;
  final TurnRole role;
  final List<ContentBlock> blocks;
  TurnStatus status;
  final String? modelId;
  List<Map<String, dynamic>> providerRaw;
  final String createdAt;
  String hlc;
  bool favorite;
  String? favoriteAt;
  bool deleted;

  String get text => blocks
      .where((block) => block.type == 'text')
      .map((block) => block.text ?? '')
      .join();

  String get reasoning => blocks
      .where((block) => block.type == 'reasoning')
      .map((block) => block.text ?? '')
      .join();

  List<ToolCall> get toolCalls => blocks
      .where((block) => block.type == 'toolCall')
      .map(
        (block) => ToolCall(
          id: block.toolCallId ?? '',
          name: block.toolName ?? '',
          argumentsJson: block.argumentsJson ?? '{}',
        ),
      )
      .toList(growable: false);

  List<ContentBlock> get images =>
      blocks.where((block) => block.type == 'image').toList(growable: false);

  List<ContentBlock> get toolResults =>
      blocks.where((block) => block.type == 'toolResult').toList(growable: false);

  bool get hasError => blocks.any((block) => block.type == 'error');

  Map<String, dynamic> toJson() => {
        'id': id,
        'conversationId': conversationId,
        'role': role.name,
        'blocks': blocks.map((block) => block.toJson()).toList(),
        'status': turnStatusToWire(status),
        if (modelId != null) 'modelId': modelId,
        'providerRaw': providerRaw,
        'createdAt': createdAt,
        'hlc': hlc,
        if (favorite) 'favorite': true,
        if (favoriteAt != null) 'favoriteAt': favoriteAt,
        'deleted': deleted,
      };

  factory Turn.fromJson(Map<String, dynamic> json) => Turn(
        id: asString(json['id']),
        conversationId: asString(json['conversationId']),
        role: turnRoleFrom(asStringOrNull(json['role'])),
        blocks: asMapList(json['blocks'])
            .map(ContentBlock.fromJson)
            .toList(growable: true),
        status: turnStatusFrom(asStringOrNull(json['status'])),
        modelId: asStringOrNull(json['modelId']),
        providerRaw: asMapList(json['providerRaw']),
        createdAt: asString(json['createdAt'], isoNow()),
        hlc: asString(json['hlc']),
        favorite: asBool(json['favorite']),
        favoriteAt: asStringOrNull(json['favoriteAt']),
        deleted: asBool(json['deleted']),
      );

  factory Turn.user({
    required String conversationId,
    required List<ContentBlock> blocks,
    required String hlc,
  }) =>
      Turn(
        id: newId('turn'),
        conversationId: conversationId,
        role: TurnRole.user,
        blocks: blocks,
        createdAt: isoNow(),
        hlc: hlc,
      );

  factory Turn.assistant({
    required String conversationId,
    required String? modelId,
    required String hlc,
    TurnStatus status = TurnStatus.streaming,
  }) =>
      Turn(
        id: newId('turn'),
        conversationId: conversationId,
        role: TurnRole.assistant,
        blocks: <ContentBlock>[],
        createdAt: isoNow(),
        hlc: hlc,
        status: status,
        modelId: modelId,
      );

  factory Turn.tool({
    required String conversationId,
    required List<ContentBlock> results,
    required String hlc,
  }) =>
      Turn(
        id: newId('turn'),
        conversationId: conversationId,
        role: TurnRole.tool,
        blocks: results,
        createdAt: isoNow(),
        hlc: hlc,
      );
}

// ---------------------------------------------------------------------------
// Conversations
// ---------------------------------------------------------------------------

class Conversation {
  Conversation({
    required this.id,
    required this.title,
    required this.accountId,
    required this.modelId,
    required this.turns,
    required this.createdAt,
    required this.updatedAt,
    required this.hlc,
    this.systemPrompt = '',
    this.contextSummary = '',
    this.summarizedThroughTurnId = '',
    this.summaryUpdatedAt = '',
    this.deleted = false,
  });

  final String id;
  String title;
  String accountId;
  String modelId;
  String systemPrompt;
  String contextSummary;
  String summarizedThroughTurnId;
  String summaryUpdatedAt;
  List<Turn> turns;
  final String createdAt;
  String updatedAt;
  String hlc;
  bool deleted;

  String get preview {
    for (final turn in turns.reversed) {
      if (turn.deleted) continue;
      final value = turn.text.trim();
      if (value.isNotEmpty) {
        return value.replaceAll('\n', ' ');
      }
    }
    return '空的对话';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'accountId': accountId,
        'modelId': modelId,
        'systemPrompt': systemPrompt,
        if (contextSummary.isNotEmpty) 'contextSummary': contextSummary,
        if (summarizedThroughTurnId.isNotEmpty)
          'summarizedThroughTurnId': summarizedThroughTurnId,
        if (summaryUpdatedAt.isNotEmpty) 'summaryUpdatedAt': summaryUpdatedAt,
        'turns': turns.map((turn) => turn.toJson()).toList(),
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'hlc': hlc,
        'deleted': deleted,
      };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: asString(json['id']),
        title: asString(json['title'], '新对话'),
        accountId: asString(json['accountId']),
        modelId: asString(json['modelId']),
        systemPrompt: asString(json['systemPrompt']),
        contextSummary: asString(json['contextSummary']),
        summarizedThroughTurnId: asString(json['summarizedThroughTurnId']),
        summaryUpdatedAt: asString(json['summaryUpdatedAt']),
        turns: asMapList(json['turns'])
            .map(Turn.fromJson)
            .toList(growable: true),
        createdAt: asString(json['createdAt'], isoNow()),
        updatedAt: asString(json['updatedAt'], isoNow()),
        hlc: asString(json['hlc']),
        deleted: asBool(json['deleted']),
      );
}

// ---------------------------------------------------------------------------
// Providers, models, attachments
// ---------------------------------------------------------------------------

class ProviderAccount {
  ProviderAccount({
    required this.id,
    required this.name,
    required this.format,
    required this.baseUrl,
    required this.defaultModelId,
    required this.createdAt,
    required this.updatedAt,
    required this.hlc,
    this.deleted = false,
  });

  final String id;
  String name;
  ProviderFormat format;
  String baseUrl;
  String defaultModelId;
  final String createdAt;
  String updatedAt;
  String hlc;
  bool deleted;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'format': format.name,
        'baseUrl': baseUrl,
        'defaultModelId': defaultModelId,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'hlc': hlc,
        'deleted': deleted,
      };

  factory ProviderAccount.fromJson(Map<String, dynamic> json) =>
      ProviderAccount(
        id: asString(json['id']),
        name: asString(json['name'], '模型服务'),
        format: providerFormatFrom(asStringOrNull(json['format'])),
        baseUrl: asString(json['baseUrl']),
        defaultModelId: asString(json['defaultModelId']),
        createdAt: asString(json['createdAt'], isoNow()),
        updatedAt: asString(json['updatedAt'], isoNow()),
        hlc: asString(json['hlc']),
        deleted: asBool(json['deleted']),
      );
}

class ModelInfo {
  ModelInfo({
    required this.id,
    required this.accountId,
    required this.modelId,
    required this.displayName,
    required this.enabled,
    required this.supportsVision,
    required this.supportsTools,
    required this.supportsReasoning,
    required this.source,
    required this.updatedAt,
    required this.hlc,
    this.deleted = false,
  });

  final String id;
  final String accountId;
  final String modelId;
  String displayName;
  bool enabled;
  bool supportsVision;
  bool supportsTools;
  bool supportsReasoning;
  String source;
  String updatedAt;
  String hlc;
  bool deleted;

  Map<String, dynamic> toJson() => {
        'id': id,
        'accountId': accountId,
        'modelId': modelId,
        'displayName': displayName,
        'enabled': enabled,
        'supportsVision': supportsVision,
        'supportsTools': supportsTools,
        'supportsReasoning': supportsReasoning,
        'source': source,
        'updatedAt': updatedAt,
        'hlc': hlc,
        'deleted': deleted,
      };

  factory ModelInfo.fromJson(Map<String, dynamic> json) => ModelInfo(
        id: asString(json['id']),
        accountId: asString(json['accountId']),
        modelId: asString(json['modelId']),
        displayName: asString(json['displayName'], asString(json['modelId'])),
        enabled: asBool(json['enabled']),
        supportsVision: asBool(json['supportsVision']),
        supportsTools: asBool(json['supportsTools']),
        supportsReasoning: asBool(json['supportsReasoning']),
        source: asString(json['source'], 'fetched'),
        updatedAt: asString(json['updatedAt'], isoNow()),
        hlc: asString(json['hlc']),
        deleted: asBool(json['deleted']),
      );
}

class ModelCapabilities {
  const ModelCapabilities({
    required this.vision,
    required this.tools,
    required this.reasoning,
  });

  final bool vision;
  final bool tools;
  final bool reasoning;
}

ModelCapabilities guessCapabilities(String modelId) {
  final id = modelId.toLowerCase();
  final vision = id.contains('gpt-4o') ||
      id.contains('gpt-4.1') ||
      id.contains('gpt-5') ||
      id.contains('claude-3') ||
      id.contains('claude-4') ||
      id.contains('claude-5') ||
      id.contains('gemini') ||
      id.contains('qwen-vl') ||
      id.contains('vision') ||
      id.contains('multimodal');
  final tools = !id.contains('embedding') &&
      !id.contains('whisper') &&
      !id.contains('tts') &&
      !id.contains('moderation');
  final reasoning = id.contains('reasoner') ||
      id.contains('thinking') ||
      id.startsWith('o1') ||
      id.startsWith('o3') ||
      id.startsWith('o4') ||
      id.contains('deepseek-r1');
  return ModelCapabilities(
    vision: vision,
    tools: tools,
    reasoning: reasoning,
  );
}

class Attachment {
  Attachment({
    required this.id,
    required this.conversationId,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.width,
    required this.height,
    required this.sha256,
    required this.createdAt,
    required this.hlc,
    this.localPath,
    this.deleted = false,
  });

  final String id;
  final String conversationId;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final int width;
  final int height;
  final String sha256;
  final String createdAt;
  String hlc;
  String? localPath;
  bool deleted;

  String get extension {
    final parts = fileName.split('.');
    if (parts.length <= 1) return 'jpg';
    return parts.last.toLowerCase();
  }

  Map<String, dynamic> toJson({bool includeLocalPath = false}) => {
        'id': id,
        'conversationId': conversationId,
        'fileName': fileName,
        'mimeType': mimeType,
        'sizeBytes': sizeBytes,
        'width': width,
        'height': height,
        'sha256': sha256,
        'createdAt': createdAt,
        'hlc': hlc,
        'deleted': deleted,
        if (includeLocalPath && localPath != null) 'localPath': localPath,
      };

  factory Attachment.fromJson(Map<String, dynamic> json) => Attachment(
        id: asString(json['id']),
        conversationId: asString(json['conversationId']),
        fileName: asString(json['fileName']),
        mimeType: asString(json['mimeType'], 'image/jpeg'),
        sizeBytes: asInt(json['sizeBytes']),
        width: asInt(json['width']),
        height: asInt(json['height']),
        sha256: asString(json['sha256']),
        createdAt: asString(json['createdAt'], isoNow()),
        hlc: asString(json['hlc']),
        localPath: asStringOrNull(json['localPath']),
        deleted: asBool(json['deleted']),
      );
}

// ---------------------------------------------------------------------------
// Long-term memory
// ---------------------------------------------------------------------------

enum MemoryCategory { preference, fact, project, general }

MemoryCategory memoryCategoryFrom(String? value) {
  for (final cat in MemoryCategory.values) {
    if (cat.name == value) return cat;
  }
  return MemoryCategory.general;
}

extension MemoryCategoryLabel on MemoryCategory {
  String get label {
    switch (this) {
      case MemoryCategory.preference:
        return '偏好';
      case MemoryCategory.fact:
        return '事实';
      case MemoryCategory.project:
        return '项目';
      case MemoryCategory.general:
        return '记忆';
    }
  }
}

class MemoryEntry {
  MemoryEntry({
    required this.id,
    required this.content,
    required this.category,
    required this.createdAt,
    required this.updatedAt,
    required this.hlc,
    this.sourceConversationId = '',
    this.deleted = false,
  });

  final String id;
  String content;
  MemoryCategory category;
  String sourceConversationId;
  final String createdAt;
  String updatedAt;
  String hlc;
  bool deleted;

  Map<String, dynamic> toJson() => {
        'id': id,
        'content': content,
        'category': category.name,
        'sourceConversationId': sourceConversationId,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'hlc': hlc,
        'deleted': deleted,
      };

  factory MemoryEntry.fromJson(Map<String, dynamic> json) => MemoryEntry(
        id: asString(json['id']),
        content: asString(json['content']),
        category: memoryCategoryFrom(asStringOrNull(json['category'])),
        sourceConversationId: asString(json['sourceConversationId']),
        createdAt: asString(json['createdAt'], isoNow()),
        updatedAt: asString(json['updatedAt'], isoNow()),
        hlc: asString(json['hlc']),
        deleted: asBool(json['deleted']),
      );
}

// ---------------------------------------------------------------------------
// Settings and peers
// ---------------------------------------------------------------------------

class AppSettings {
  AppSettings({
    required this.deviceId,
    required this.deviceName,
    required this.theme,
    required this.defaultSystemPrompt,
    required this.maxTokens,
    required this.temperature,
    required this.showReasoning,
    required this.enableCodeTools,
    required this.enableShellTool,
    required this.enableWebSearch,
    required this.searchProvider,
    required this.searchResultCount,
    required this.pythonPath,
    required this.hlc,
    this.enableAutoSummary = true,
    this.summaryTriggerTurns = 16,
    this.summaryKeepRecentTurns = 6,
    this.enableMemory = true,
    this.autoExtractMemory = true,
    this.memoryExtractIntervalTurns = 6,
    this.maxMemoryEntries = 24,
    this.turnsSinceMemoryExtract = 0,
    this.memoryMaintenanceCycles = 0,
    this.lastMemoryMaintenanceAt = '',
    this.deleted = false,
  });

  factory AppSettings.defaults({
    required String deviceId,
    required String deviceName,
  }) =>
      AppSettings(
        deviceId: deviceId,
        deviceName: deviceName,
        theme: ThemePreference.system,
        defaultSystemPrompt: '',
        maxTokens: 8192,
        temperature: 0.7,
        showReasoning: true,
        enableCodeTools: false,
        enableShellTool: false,
        enableWebSearch: true,
        searchProvider: SearchProvider.duckduckgo,
        searchResultCount: 5,
        pythonPath: Platform.isWindows ? 'python' : 'python3',
        hlc: '',
      );

  final String deviceId;
  String deviceName;
  ThemePreference theme;
  String defaultSystemPrompt;
  int maxTokens;
  double? temperature;
  bool showReasoning;
  bool enableCodeTools;
  bool enableShellTool;
  bool enableWebSearch;
  SearchProvider searchProvider;
  int searchResultCount;
  String pythonPath;
  String hlc;
  bool enableAutoSummary;
  int summaryTriggerTurns;
  int summaryKeepRecentTurns;
  bool enableMemory;
  bool autoExtractMemory;
  int memoryExtractIntervalTurns;
  int maxMemoryEntries;
  int turnsSinceMemoryExtract;
  int memoryMaintenanceCycles;
  String lastMemoryMaintenanceAt;
  bool deleted;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'theme': theme.name,
        'defaultSystemPrompt': defaultSystemPrompt,
        'maxTokens': maxTokens,
        'temperature': temperature,
        'showReasoning': showReasoning,
        'enableCodeTools': enableCodeTools,
        'enableShellTool': enableShellTool,
        'enableWebSearch': enableWebSearch,
        'searchProvider': searchProviderToWire(searchProvider),
        'searchResultCount': searchResultCount,
        'pythonPath': pythonPath,
        'enableAutoSummary': enableAutoSummary,
        'summaryTriggerTurns': summaryTriggerTurns,
        'summaryKeepRecentTurns': summaryKeepRecentTurns,
        'enableMemory': enableMemory,
        'autoExtractMemory': autoExtractMemory,
        'memoryExtractIntervalTurns': memoryExtractIntervalTurns,
        'maxMemoryEntries': maxMemoryEntries,
        'turnsSinceMemoryExtract': turnsSinceMemoryExtract,
        'memoryMaintenanceCycles': memoryMaintenanceCycles,
        'lastMemoryMaintenanceAt': lastMemoryMaintenanceAt,
        'hlc': hlc,
        'deleted': deleted,
      };

  Map<String, dynamic> toSyncJson() => {
        'defaultSystemPrompt': defaultSystemPrompt,
        'maxTokens': maxTokens,
        'temperature': temperature,
        'showReasoning': showReasoning,
        'enableCodeTools': enableCodeTools,
        'enableShellTool': enableShellTool,
        'enableWebSearch': enableWebSearch,
        'searchProvider': searchProviderToWire(searchProvider),
        'searchResultCount': searchResultCount,
        'enableAutoSummary': enableAutoSummary,
        'summaryTriggerTurns': summaryTriggerTurns,
        'summaryKeepRecentTurns': summaryKeepRecentTurns,
        'enableMemory': enableMemory,
        'autoExtractMemory': autoExtractMemory,
        'memoryExtractIntervalTurns': memoryExtractIntervalTurns,
        'maxMemoryEntries': maxMemoryEntries,
        'hlc': hlc,
        'deleted': deleted,
      };

  void applySyncJson(Map<String, dynamic> json) {
    defaultSystemPrompt = asString(
      json['defaultSystemPrompt'],
      defaultSystemPrompt,
    );
    maxTokens = asInt(json['maxTokens'], maxTokens);
    temperature = asDoubleOrNull(json['temperature']);
    showReasoning = asBool(json['showReasoning'], showReasoning);
    enableCodeTools = asBool(json['enableCodeTools'], enableCodeTools);
    enableShellTool = asBool(json['enableShellTool'], enableShellTool);
    enableWebSearch = asBool(json['enableWebSearch'], enableWebSearch);
    searchProvider = searchProviderFrom(asStringOrNull(json['searchProvider']));
    searchResultCount = asInt(json['searchResultCount'], searchResultCount);
    enableAutoSummary = asBool(json['enableAutoSummary'], enableAutoSummary);
    summaryTriggerTurns = asInt(
      json['summaryTriggerTurns'],
      summaryTriggerTurns,
    );
    summaryKeepRecentTurns = asInt(
      json['summaryKeepRecentTurns'],
      summaryKeepRecentTurns,
    );
    enableMemory = asBool(json['enableMemory'], enableMemory);
    autoExtractMemory = asBool(json['autoExtractMemory'], autoExtractMemory);
    memoryExtractIntervalTurns = asInt(
      json['memoryExtractIntervalTurns'],
      memoryExtractIntervalTurns,
    );
    maxMemoryEntries = asInt(json['maxMemoryEntries'], maxMemoryEntries);
    hlc = asString(json['hlc'], hlc);
    deleted = asBool(json['deleted']);
  }

  factory AppSettings.fromJson(Map<String, dynamic> json, String fallbackId) =>
      AppSettings(
        deviceId: asString(json['deviceId'], fallbackId),
        deviceName: asString(json['deviceName'], '此设备'),
        theme: themePreferenceFrom(asStringOrNull(json['theme'])),
        defaultSystemPrompt: asString(json['defaultSystemPrompt']),
        maxTokens: asInt(json['maxTokens'], 8192),
        temperature: asDoubleOrNull(json['temperature']),
        showReasoning: asBool(json['showReasoning'], true),
        enableCodeTools: asBool(json['enableCodeTools']),
        enableShellTool: asBool(json['enableShellTool']),
        enableWebSearch: asBool(json['enableWebSearch'], true),
        searchProvider: searchProviderFrom(asStringOrNull(json['searchProvider'])),
        searchResultCount: asInt(json['searchResultCount'], 5),
        pythonPath: asString(
          json['pythonPath'],
          Platform.isWindows ? 'python' : 'python3',
        ),
        enableAutoSummary: asBool(json['enableAutoSummary'], true),
        summaryTriggerTurns: asInt(json['summaryTriggerTurns'], 16).clamp(6, 200),
        summaryKeepRecentTurns:
            asInt(json['summaryKeepRecentTurns'], 6).clamp(2, 50),
        enableMemory: asBool(json['enableMemory'], true),
        autoExtractMemory: asBool(json['autoExtractMemory'], true),
        memoryExtractIntervalTurns:
            asInt(json['memoryExtractIntervalTurns'], 6).clamp(2, 100),
        maxMemoryEntries: asInt(json['maxMemoryEntries'], 24).clamp(5, 200),
        turnsSinceMemoryExtract: asInt(json['turnsSinceMemoryExtract']),
        memoryMaintenanceCycles: asInt(json['memoryMaintenanceCycles']),
        lastMemoryMaintenanceAt: asString(json['lastMemoryMaintenanceAt']),
        hlc: asString(json['hlc']),
        deleted: asBool(json['deleted']),
      );
}

class PeerDevice {
  PeerDevice({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.lastSeen,
    this.isHost = true,
    this.hostAddress,
    this.hostPort = 0,
  });

  final String deviceId;
  String name;
  final String platform;
  String lastSeen;
  final bool isHost;
  final String? hostAddress;
  final int hostPort;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'platform': platform,
        'lastSeen': lastSeen,
        'isHost': isHost,
        if (hostAddress != null) 'hostAddress': hostAddress,
        'hostPort': hostPort,
      };

  factory PeerDevice.fromJson(Map<String, dynamic> json) => PeerDevice(
        deviceId: asString(json['deviceId']),
        name: asString(json['name'], '设备'),
        platform: asString(json['platform'], 'unknown'),
        lastSeen: asString(json['lastSeen'], isoNow()),
        isHost: asBool(json['isHost'], true),
        hostAddress: asStringOrNull(json['hostAddress']),
        hostPort: asInt(json['hostPort']),
      );
}
