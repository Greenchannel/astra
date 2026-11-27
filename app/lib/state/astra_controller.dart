import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../data/agent/agent_runner.dart';
import '../data/attachments/attachment_service.dart';
import '../data/memory/memory_service.dart';
import '../data/models/models.dart';
import '../data/platform/python_runtime.dart';
import '../data/providers/llm_client.dart';
import '../data/providers/provider_common.dart';
import '../data/storage/app_repository.dart';
import '../data/storage/secret_store.dart';
import '../data/sync/sync_service.dart';
import '../data/tools/tool_registry.dart';
import '../data/tools/web_search_tool.dart';
import '../util/hlc.dart';
import '../util/ids.dart';

class AstraController extends ChangeNotifier {
  AstraController({
    AppRepository? repository,
    SecretStore? secrets,
    LlmClient? llmClient,
    AttachmentService? attachmentService,
  })  : repo = repository ?? AppRepository(),
        _secrets = secrets ?? SecretStore(),
        _llm = llmClient ?? LlmClient(),
        _attachments = attachmentService ?? AttachmentService();

  final AppRepository repo;
  final SecretStore _secrets;
  final LlmClient _llm;
  final AttachmentService _attachments;

  late final HlcClock clock;
  late final ToolRegistry tools;
  late final SyncService sync;
  late final PythonRuntime _pythonRuntime;
  late final WebSearchService _webSearch;
  late final MemoryService _memoryService = MemoryService(client: _llm);

  bool ready = false;
  bool generating = false;
  bool memoryBusy = false;
  bool _disposed = false;
  String? lastError;
  String? currentConversationId;
  String? scrollToTurnId;
  ToolApprovalRequest? pendingApproval;

  final Map<String, bool> _accountKeyPresence = {};
  final Map<SearchProvider, bool> _searchKeyPresence = {};

  CancelToken? _cancelToken;
  Completer<bool>? _approvalCompleter;

  AppSettings get settings => repo.settings;
  List<ProviderAccount> get accounts => repo.visibleAccounts;
  List<Conversation> get conversations => repo.visibleConversations;
  List<MemoryEntry> get memories => repo.visibleMemories;
  Conversation? get currentConversation =>
      currentConversationId == null ? null : repo.conversation(currentConversationId!);

  List<({Conversation conversation, Turn turn})> get favoriteTurns {
    final items = <({Conversation conversation, Turn turn})>[];
    for (final conversation in conversations) {
      for (final turn in conversation.turns) {
        if (!turn.deleted && turn.role == TurnRole.assistant && turn.favorite) {
          items.add((conversation: conversation, turn: turn));
        }
      }
    }
    items.sort((a, b) {
      final aKey = a.turn.favoriteAt ?? a.turn.createdAt;
      final bKey = b.turn.favoriteAt ?? b.turn.createdAt;
      return bKey.compareTo(aKey);
    });
    return items;
  }

  List<ModelInfo> modelsFor(String accountId, {bool enabledOnly = true}) =>
      repo.modelsFor(accountId, enabledOnly: enabledOnly);

  bool hasAccountKey(String accountId) =>
      _accountKeyPresence[accountId] ?? false;

  bool hasSearchKey(SearchProvider provider) =>
      _searchKeyPresence[provider] ?? false;

  Future<void> init() async {
    await repo.init();
    clock = HlcClock(repo.settings.deviceId);
    _pythonRuntime = PythonRuntime();
    _webSearch = WebSearchService();
    tools = ToolRegistry(
      pythonRuntime: _pythonRuntime,
      webSearch: _webSearch,
    );
    await _ensureHlcs();
    await _refreshKeyPresence();
    sync = SyncService(
      repository: repo,
      secrets: _secrets,
      clock: clock,
      onDataChanged: _onRemoteData,
      onStatusChanged: notifyListeners,
    );
    currentConversationId = conversations.isEmpty ? null : conversations.first.id;
    ready = true;
    notifyListeners();
    unawaited(sync.init());
  }

  Future<void> _ensureHlcs() async {
    var changed = false;
    String next() {
      changed = true;
      return clock.next().encode();
    }

    if (repo.settings.hlc.isEmpty) repo.settings.hlc = next();
    for (final account in repo.accounts) {
      if (account.hlc.isEmpty) account.hlc = next();
    }
    for (final model in repo.models) {
      if (model.hlc.isEmpty) model.hlc = next();
    }
    for (final attachment in repo.attachments) {
      if (attachment.hlc.isEmpty) attachment.hlc = next();
    }
    for (final memory in repo.memories) {
      if (memory.hlc.isEmpty) memory.hlc = next();
    }
    for (final conversation in repo.conversations) {
      if (conversation.hlc.isEmpty) conversation.hlc = next();
      for (final turn in conversation.turns) {
        if (turn.hlc.isEmpty) turn.hlc = next();
      }
    }
    if (changed) {
      await repo.saveSettings();
      await repo.saveAccounts();
      await repo.saveModels();
      await repo.saveConversations();
      await repo.saveAttachments();
      await repo.saveMemories();
    }
  }

  Future<void> _refreshKeyPresence() async {
    for (final account in repo.visibleAccounts) {
      try {
        final key = await _secrets.apiKey(account.id);
        _accountKeyPresence[account.id] = key != null && key.isNotEmpty;
      } catch (_) {
        _accountKeyPresence[account.id] = false;
      }
    }
    for (final provider in [SearchProvider.tavily, SearchProvider.brave]) {
      try {
        final key = await _secrets.searchKey(provider.name);
        _searchKeyPresence[provider] = key != null && key.isNotEmpty;
      } catch (_) {
        _searchKeyPresence[provider] = false;
      }
    }
  }

  void _onRemoteData() {
    if (currentConversationId != null &&
        repo.conversation(currentConversationId!) == null) {
      currentConversationId =
          conversations.isEmpty ? null : conversations.first.id;
    }
    unawaited(
      _refreshKeyPresence().then((_) {
        if (ready) notifyListeners();
      }),
    );
    notifyListeners();
  }

  void clearError() {
    lastError = null;
    notifyListeners();
  }

  void onAppResumed() {
    unawaited(sync.reconnectPeers());
  }

  // ---------------------------------------------------------------- accounts
  Future<ProviderAccount> saveAccount({
    String? id,
    required String name,
    required ProviderFormat format,
    required String baseUrl,
    String apiKey = '',
    String? defaultModelId,
  }) async {
    final trimmedName = name.trim().isEmpty
        ? (format == ProviderFormat.anthropic ? 'Claude' : 'OpenAI')
        : name.trim();
    final trimmedUrl = baseUrl.trim();
    final uri = Uri.tryParse(trimmedUrl);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw ProviderException(null, 'Base URL 必须是完整的 http(s) 地址。');
    }
    ProviderAccount account;
    if (id == null) {
      account = ProviderAccount(
        id: newId('account'),
        name: trimmedName,
        format: format,
        baseUrl: trimmedUrl,
        defaultModelId: defaultModelId ?? '',
        createdAt: isoNow(),
        updatedAt: isoNow(),
        hlc: clock.next().encode(),
      );
      repo.accounts.add(account);
    } else {
      final existing = repo.account(id);
      if (existing == null) throw StateError('账户不存在。');
      existing
        ..name = trimmedName
        ..format = format
        ..baseUrl = trimmedUrl
        ..updatedAt = isoNow()
        ..hlc = clock.next().encode();
      if (defaultModelId != null) existing.defaultModelId = defaultModelId;
      account = existing;
    }
    if (apiKey.trim().isNotEmpty) {
      await _secrets.setApiKey(account.id, apiKey.trim());
      _accountKeyPresence[account.id] = true;
    }
    await repo.saveAccounts();
    sync.notifyLocalChange();
    notifyListeners();
    return account;
  }

  Future<void> deleteAccount(String accountId) async {
    final account = repo.account(accountId);
    if (account == null) return;
    account
      ..deleted = true
      ..updatedAt = isoNow()
      ..hlc = clock.next().encode();
    for (final model in repo.modelsFor(accountId, enabledOnly: false)) {
      model
        ..deleted = true
        ..hlc = clock.next().encode();
    }
    try {
      await _secrets.deleteApiKey(accountId);
    } catch (_) {
      // Key cleanup is best effort.
    }
    _accountKeyPresence.remove(accountId);
    await repo.saveAccounts();
    await repo.saveModels();
    sync.notifyLocalChange();
    notifyListeners();
  }

  Future<int> fetchModels(String accountId) async {
    final account = repo.account(accountId);
    if (account == null) throw StateError('账户不存在。');
    final key = await _secrets.apiKey(accountId);
    if (key == null || key.isEmpty) {
      throw ProviderException(null, '请先保存该服务的 API Key。');
    }
    final remote = await _llm.fetchModels(account: account, apiKey: key);
    for (final item in remote) {
      final existing = repo.modelByModelId(accountId, item.id);
      if (existing == null) {
        final caps = guessCapabilities(item.id);
        repo.models.add(
          ModelInfo(
            id: newId('model'),
            accountId: accountId,
            modelId: item.id,
            displayName: item.displayName,
            enabled: true,
            supportsVision: caps.vision,
            supportsTools: caps.tools,
            supportsReasoning: caps.reasoning,
            source: 'fetched',
            updatedAt: isoNow(),
            hlc: clock.next().encode(),
          ),
        );
      } else if (existing.displayName != item.displayName) {
        existing
          ..displayName = item.displayName
          ..updatedAt = isoNow()
          ..hlc = clock.next().encode();
      }
    }
    if (account.defaultModelId.isEmpty ||
        repo.modelByModelId(accountId, account.defaultModelId) == null) {
      final enabled = repo.modelsFor(accountId, enabledOnly: true);
      if (enabled.isNotEmpty) account.defaultModelId = enabled.first.modelId;
    }
    account
      ..updatedAt = isoNow()
      ..hlc = clock.next().encode();
    await repo.saveModels();
    await repo.saveAccounts();
    sync.notifyLocalChange();
    notifyListeners();
    return remote.length;
  }

  Future<void> addManualModel({
    required String accountId,
    required String modelId,
    required String displayName,
  }) async {
    final trimmed = modelId.trim();
    if (trimmed.isEmpty) throw StateError('模型 ID 不能为空。');
    final existing = repo.modelByModelId(accountId, trimmed);
    if (existing != null) {
      existing
        ..deleted = false
        ..enabled = true
        ..updatedAt = isoNow()
        ..hlc = clock.next().encode();
    } else {
      final caps = guessCapabilities(trimmed);
      repo.models.add(
        ModelInfo(
          id: newId('model'),
          accountId: accountId,
          modelId: trimmed,
          displayName: displayName.trim().isEmpty ? trimmed : displayName.trim(),
          enabled: true,
          supportsVision: caps.vision,
          supportsTools: caps.tools,
          supportsReasoning: caps.reasoning,
          source: 'manual',
          updatedAt: isoNow(),
          hlc: clock.next().encode(),
        ),
      );
    }
    final account = repo.account(accountId);
    if (account != null && account.defaultModelId.isEmpty) {
      account.defaultModelId = trimmed;
      await repo.saveAccounts();
    }
    await repo.saveModels();
    sync.notifyLocalChange();
    notifyListeners();
  }

  Future<void> updateModel(
    ModelInfo model, {
    bool? enabled,
    bool? vision,
    bool? tools,
    bool? reasoning,
  }) async {
    if (enabled != null) model.enabled = enabled;
    if (vision != null) model.supportsVision = vision;
    if (tools != null) model.supportsTools = tools;
    if (reasoning != null) model.supportsReasoning = reasoning;
    model
      ..updatedAt = isoNow()
      ..hlc = clock.next().encode();
    final account = repo.account(model.accountId);
    if (account != null &&
        !model.enabled &&
        account.defaultModelId == model.modelId) {
      final remaining = repo.modelsFor(model.accountId, enabledOnly: true);
      account
        ..defaultModelId = remaining.isEmpty ? '' : remaining.first.modelId
        ..updatedAt = isoNow()
        ..hlc = clock.next().encode();
      await repo.saveAccounts();
    }
    await repo.saveModels();
    sync.notifyLocalChange();
    notifyListeners();
  }

  Future<void> setDefaultModel(String accountId, String modelId) async {
    final account = repo.account(accountId);
    if (account == null) return;
    account
      ..defaultModelId = modelId
      ..updatedAt = isoNow()
      ..hlc = clock.next().encode();
    await repo.saveAccounts();
    sync.notifyLocalChange();
    notifyListeners();
  }

  ModelInfo? defaultModelFor(String accountId) {
    final account = repo.account(accountId);
    if (account == null) return null;
    final selected = repo.modelByModelId(accountId, account.defaultModelId);
    if (selected != null && selected.enabled && !selected.deleted) return selected;
    final enabled = repo.modelsFor(accountId, enabledOnly: true);
    return enabled.isEmpty ? null : enabled.first;
  }

  // ------------------------------------------------------------ conversations
  Conversation? newConversation({String? accountId}) {
    final account = accountId == null
        ? (accounts.isEmpty ? null : accounts.first)
        : repo.account(accountId);
    if (account == null) {
      lastError = '请先在设置中添加模型服务。';
      notifyListeners();
      return null;
    }
    final model = defaultModelFor(account.id);
    if (model == null) {
      lastError = '该服务还没有可用的模型，请先在设置中拉取或添加模型。';
      notifyListeners();
      return null;
    }
    final conversation = Conversation(
      id: newId('chat'),
      title: '新对话',
      accountId: account.id,
      modelId: model.modelId,
      turns: [],
      createdAt: isoNow(),
      updatedAt: isoNow(),
      hlc: clock.next().encode(),
      systemPrompt: '',
    );
    repo.conversations.add(conversation);
    currentConversationId = conversation.id;
    lastError = null;
    unawaited(repo.saveConversations());
    sync.notifyLocalChange();
    notifyListeners();
    return conversation;
  }

  void selectConversation(String id, {String? focusTurnId}) {
    if (repo.conversation(id) == null) return;
    currentConversationId = id;
    scrollToTurnId = focusTurnId;
    notifyListeners();
  }

  void clearScrollToTurn() {
    scrollToTurnId = null;
  }

  Future<void> toggleFavoriteTurn(String conversationId, String turnId) async {
    final conversation = repo.conversation(conversationId);
    if (conversation == null) return;
    final idx = conversation.turns.indexWhere(
      (turn) => turn.id == turnId && !turn.deleted,
    );
    if (idx < 0) return;
    final turn = conversation.turns[idx];
    turn.favorite = !turn.favorite;
    turn.favoriteAt = turn.favorite ? isoNow() : null;
    turn.hlc = clock.next().encode();
    await _checkpointConversation(conversation);
    notifyListeners();
  }

  Future<void> renameConversation(String id, String title) async {
    final conversation = repo.conversation(id);
    if (conversation == null) return;
    conversation
      ..title = title.trim().isEmpty ? conversation.title : title.trim()
      ..updatedAt = isoNow()
      ..hlc = clock.next().encode();
    await repo.saveConversations();
    sync.notifyLocalChange();
    notifyListeners();
  }

  Future<void> setConversationModel(String modelId) async {
    final conversation = currentConversation;
    if (conversation == null) return;
    final model = repo.modelByModelId(conversation.accountId, modelId);
    if (model == null || !model.enabled) return;
    conversation
      ..modelId = model.modelId
      ..updatedAt = isoNow()
      ..hlc = clock.next().encode();
    await repo.saveConversations();
    sync.notifyLocalChange();
    notifyListeners();
  }

  Future<void> setConversationPrompt(String value) async {
    final conversation = currentConversation;
    if (conversation == null) return;
    conversation
      ..systemPrompt = value
      ..updatedAt = isoNow()
      ..hlc = clock.next().encode();
    await repo.saveConversations();
    sync.notifyLocalChange();
    notifyListeners();
  }

  Future<void> deleteConversation(String id) async {
    final conversation = repo.conversation(id);
    if (conversation == null) return;
    conversation
      ..deleted = true
      ..updatedAt = isoNow()
      ..hlc = clock.next().encode();
    await repo.saveConversations();
    if (currentConversationId == id) {
      currentConversationId =
          conversations.isEmpty ? null : conversations.first.id;
    }
    sync.notifyLocalChange();
    notifyListeners();
  }

  // ------------------------------------------------------------------- chat
  Future<List<PendingImage>> pickImages() async {
    try {
      return await _attachments.pickImages();
    } catch (error) {
      _fail('$error');
      return const [];
    }
  }

  Future<void> sendMessage(
    String text, {
    List<PendingImage> images = const [],
  }) async {
    if (generating) return;
    final conversation = currentConversation;
    if (conversation == null) {
      newConversation();
      return;
    }
    final account = repo.account(conversation.accountId);
    if (account == null) {
      _fail('该对话的模型服务已被删除。');
      return;
    }
    final model = repo.modelByModelId(account.id, conversation.modelId);
    if (model == null || model.deleted || !model.enabled) {
      _fail('当前模型不可用，请在顶部重新选择模型。');
      return;
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty && images.isEmpty) return;
    final key = await _secrets.apiKey(account.id);
    if (key == null || key.isEmpty) {
      _fail('还没有配置该服务的 API Key。');
      return;
    }

    try {
      final blocks = <ContentBlock>[];
      if (trimmed.isNotEmpty) blocks.add(ContentBlock.text(trimmed));
      for (final image in images) {
        final sha = await _attachments.sha256Hex(image.bytes);
        final attachment = Attachment(
          id: newId('img'),
          conversationId: conversation.id,
          fileName: image.fileName,
          mimeType: image.mimeType,
          sizeBytes: image.bytes.length,
          width: image.width,
          height: image.height,
          sha256: sha,
          createdAt: isoNow(),
          hlc: clock.next().encode(),
        );
        await repo.upsertAttachment(attachment, image.bytes);
        blocks.add(ContentBlock.image(attachment.id));
      }

      final userTurn = Turn.user(
        conversationId: conversation.id,
        blocks: blocks,
        hlc: clock.next().encode(),
      );
      conversation.turns.add(userTurn);
      if (conversation.title == '新对话' || conversation.title.isEmpty) {
        final firstText = trimmed.isEmpty ? '图片对话' : trimmed;
        conversation.title = firstText.length > 32
            ? '${firstText.substring(0, 32)}…'
            : firstText;
      }
      conversation
        ..updatedAt = isoNow()
        ..hlc = clock.next().encode();
      await repo.saveConversations();
      sync.notifyLocalChange();

      if (pendingApproval != null) {
        _approvalCompleter?.complete(false);
        pendingApproval = null;
        _approvalCompleter = null;
      }
      generating = true;
      lastError = null;
      final cancelToken = CancelToken();
      _cancelToken = cancelToken;
      notifyListeners();

      final imagePayloads = await _loadRecentImages(conversation);
      final workspace = await repo.paths.workspaceFor(conversation.id);
      final tavilyKey = await _secrets.searchKey('tavily');
      final braveKey = await _secrets.searchKey('brave');
      final basePrompt = conversation.systemPrompt.trim().isNotEmpty
          ? conversation.systemPrompt
          : settings.defaultSystemPrompt;
      final effectiveContext = MemoryService.buildEffectiveContext(
        conversation: conversation,
        baseSystemPrompt: basePrompt,
        memories: memories,
        settings: settings,
      );

      final runner = AgentRunner(client: _llm, tools: tools);
      var completedCleanly = false;
      try {
        await runner.run(
          account: account,
          model: model,
          apiKey: key,
          conversationTitle: conversation.title,
          turns: conversation.turns,
          images: imagePayloads,
          systemPrompt: effectiveContext.systemPrompt,
          summarizedThroughTurnId: conversation.summarizedThroughTurnId,
          settings: settings,
          toolContext: ToolContext(
            workspace: workspace,
            settings: settings,
            tavilyKey: tavilyKey,
            braveKey: braveKey,
          ),
          nextHlc: () => clock.next().encode(),
          approve: _requestApproval,
          onUpdate: notifyListeners,
          onCheckpoint: () => _checkpointConversation(conversation),
          cancelToken: cancelToken,
        );
        completedCleanly = !cancelToken.isCancelled;
      } on AgentFailure catch (error) {
        lastError = error.message;
      } catch (error) {
        lastError = '对话失败：$error';
      } finally {
        generating = false;
        _cancelToken = null;
        pendingApproval = null;
        final completer = _approvalCompleter;
        _approvalCompleter = null;
        if (completer != null && !completer.isCompleted) completer.complete(false);
        await _checkpointConversation(conversation);
        notifyListeners();
      }
      if (completedCleanly && !_disposed) {
        unawaited(
          _runPostTurnMemoryMaintenance(
            conversation: conversation,
            account: account,
            model: model,
            apiKey: key,
          ),
        );
      }
    } catch (error) {
      generating = false;
      _cancelToken = null;
      lastError = '发送失败：$error';
      notifyListeners();
    }
  }

  Future<void> _checkpointConversation(Conversation conversation) async {
    conversation
      ..updatedAt = isoNow()
      ..hlc = clock.next().encode();
    await repo.saveConversations();
    sync.notifyLocalChange();
  }

  Future<Map<String, ImagePayload>> _loadRecentImages(
    Conversation conversation,
  ) async {
    final ids = <String>{};
    var userTurns = 0;
    for (final turn in conversation.turns.reversed) {
      if (turn.deleted) continue;
      if (turn.role == TurnRole.user) {
        userTurns++;
        if (userTurns > 6) break;
      }
      for (final block in turn.images) {
        if (block.attachmentId != null) ids.add(block.attachmentId!);
      }
    }
    final result = <String, ImagePayload>{};
    for (final id in ids) {
      final attachment = repo.attachment(id);
      if (attachment == null) continue;
      final bytes = await repo.readAttachment(attachment);
      if (bytes == null) continue;
      result[id] = ImagePayload(
        mimeType: attachment.mimeType,
        bytes: Uint8List.fromList(bytes),
      );
    }
    return result;
  }

  Future<bool> _requestApproval(ToolApprovalRequest request) async {
    if (!generating) return false;
    final completer = Completer<bool>();
    _approvalCompleter = completer;
    pendingApproval = request;
    notifyListeners();
    final result = await completer.future;
    if (identical(_approvalCompleter, completer)) {
      _approvalCompleter = null;
      pendingApproval = null;
    }
    notifyListeners();
    return result;
  }

  void resolveToolApproval(bool approved) {
    final completer = _approvalCompleter;
    _approvalCompleter = null;
    pendingApproval = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(approved);
    }
    notifyListeners();
  }

  Future<void> stopGeneration() async {
    if (!generating) return;
    _cancelToken?.cancel();
    final completer = _approvalCompleter;
    _approvalCompleter = null;
    pendingApproval = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(false);
    }
    notifyListeners();
  }

  void _fail(String message) {
    lastError = message;
    notifyListeners();
  }

  // ---------------------------------------------------------------- memory
  Future<void> _runPostTurnMemoryMaintenance({
    required Conversation conversation,
    required ProviderAccount account,
    required ModelInfo model,
    required String apiKey,
  }) async {
    if (memoryBusy || _disposed) return;
    memoryBusy = true;
    notifyListeners();
    try {
      if (settings.enableAutoSummary) {
        await _compactConversationInternal(
          conversation: conversation,
          account: account,
          model: model,
          apiKey: apiKey,
          force: false,
        );
      }
      if (settings.enableMemory && settings.autoExtractMemory) {
        settings.turnsSinceMemoryExtract += 1;
        await repo.saveSettings();
        if (settings.turnsSinceMemoryExtract >=
            settings.memoryExtractIntervalTurns) {
          await _extractAndMaybeCompressMemories(
            conversation: conversation,
            account: account,
            model: model,
            apiKey: apiKey,
          );
        }
      }
    } catch (_) {
      // Background memory maintenance must never interrupt active chat UX.
    } finally {
      memoryBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<bool> compactConversationNow(String conversationId) async {
    final conversation = repo.conversation(conversationId);
    if (conversation == null) return false;
    final resolved = await _resolveModelAndKey(conversation: conversation);
    if (resolved == null) {
      throw StateError('请先配置可用的模型服务和 API Key。');
    }
    memoryBusy = true;
    notifyListeners();
    try {
      return await _compactConversationInternal(
        conversation: conversation,
        account: resolved.account,
        model: resolved.model,
        apiKey: resolved.apiKey,
        force: true,
      );
    } finally {
      memoryBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> clearConversationSummary(String conversationId) async {
    final conversation = repo.conversation(conversationId);
    if (conversation == null) return;
    conversation
      ..contextSummary = ''
      ..summarizedThroughTurnId = ''
      ..summaryUpdatedAt = isoNow()
      ..updatedAt = isoNow()
      ..hlc = clock.next().encode();
    await repo.saveConversations();
    sync.notifyLocalChange();
    notifyListeners();
  }

  Future<int> extractMemoryNow({String? conversationId}) async {
    final target = conversationId != null
        ? repo.conversation(conversationId)
        : currentConversation ??
            (conversations.isEmpty ? null : conversations.first);
    if (target == null) {
      throw StateError('没有可用于提取记忆的对话。');
    }
    final resolved = await _resolveModelAndKey(conversation: target);
    if (resolved == null) {
      throw StateError('请先配置可用的模型服务和 API Key。');
    }
    memoryBusy = true;
    notifyListeners();
    try {
      return await _extractAndMaybeCompressMemories(
        conversation: target,
        account: resolved.account,
        model: resolved.model,
        apiKey: resolved.apiKey,
      );
    } finally {
      memoryBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<int> compressMemoriesNow() async {
    final active = memories;
    if (active.length <= 1) return active.length;
    final resolved = await _resolveModelAndKey(conversation: currentConversation);
    if (resolved == null) {
      throw StateError('请先配置可用的模型服务和 API Key。');
    }
    memoryBusy = true;
    notifyListeners();
    try {
      return await _compressMemoriesInternal(
        account: resolved.account,
        model: resolved.model,
        apiKey: resolved.apiKey,
      );
    } finally {
      memoryBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> addMemory({
    required String content,
    required MemoryCategory category,
  }) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return;
    repo.memories.add(
      newMemoryEntry(
        content: trimmed,
        category: category,
        hlc: clock.next().encode(),
      ),
    );
    await repo.saveMemories();
    sync.notifyLocalChange();
    notifyListeners();
  }

  Future<void> updateMemory(
    MemoryEntry entry, {
    required String content,
    required MemoryCategory category,
  }) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return;
    entry
      ..content = trimmed
      ..category = category
      ..updatedAt = isoNow()
      ..hlc = clock.next().encode();
    await repo.saveMemories();
    sync.notifyLocalChange();
    notifyListeners();
  }

  Future<void> deleteMemory(String id) async {
    final entry = repo.memory(id);
    if (entry == null) return;
    entry
      ..deleted = true
      ..updatedAt = isoNow()
      ..hlc = clock.next().encode();
    await repo.saveMemories();
    sync.notifyLocalChange();
    notifyListeners();
  }

  Future<bool> _compactConversationInternal({
    required Conversation conversation,
    required ProviderAccount account,
    required ModelInfo model,
    required String apiKey,
    required bool force,
  }) async {
    final plan = MemoryService.planConversationCompaction(
      conversation,
      triggerTurns: settings.summaryTriggerTurns,
      keepRecentTurns: settings.summaryKeepRecentTurns,
      force: force,
    );
    if (plan == null) return false;
    final summary = await _memoryService.summarizeTurns(
      account: account,
      model: model,
      apiKey: apiKey,
      existingSummary: conversation.contextSummary,
      plan: plan,
      settings: settings,
    );
    if (summary.isEmpty) return false;
    conversation
      ..contextSummary = summary
      ..summarizedThroughTurnId = plan.lastSummarizedTurnId
      ..summaryUpdatedAt = isoNow()
      ..updatedAt = isoNow()
      ..hlc = clock.next().encode();
    await repo.saveConversations();
    sync.notifyLocalChange();
    return true;
  }

  Future<int> _extractAndMaybeCompressMemories({
    required Conversation conversation,
    required ProviderAccount account,
    required ModelInfo model,
    required String apiKey,
  }) async {
    final activeTurns = conversation.turns
        .where((turn) => !turn.deleted)
        .toList(growable: false);
    final tailStart = activeTurns.length > 10 ? activeTurns.length - 10 : 0;
    final recentTurns = activeTurns.sublist(tailStart);
    final drafts = await _memoryService.extractMemories(
      account: account,
      model: model,
      apiKey: apiKey,
      recentTurns: recentTurns,
      existingMemories: memories,
      settings: settings,
    );

    final existingLower =
        memories.map((item) => item.content.trim().toLowerCase()).toSet();
    var added = 0;
    for (final draft in drafts) {
      if (existingLower.contains(draft.content.toLowerCase())) continue;
      repo.memories.add(
        newMemoryEntry(
          content: draft.content,
          category: draft.category,
          sourceConversationId: conversation.id,
          hlc: clock.next().encode(),
        ),
      );
      existingLower.add(draft.content.toLowerCase());
      added++;
    }

    settings
      ..turnsSinceMemoryExtract = 0
      ..memoryMaintenanceCycles += 1;

    if (MemoryService.shouldCompressMemories(
      activeMemories: memories,
      settings: settings,
    )) {
      await _compressMemoriesInternal(
        account: account,
        model: model,
        apiKey: apiKey,
      );
    } else {
      await repo.saveMemories();
      await repo.saveSettings();
      sync.notifyLocalChange();
    }
    return added;
  }

  Future<int> _compressMemoriesInternal({
    required ProviderAccount account,
    required ModelInfo model,
    required String apiKey,
  }) async {
    final current = memories;
    if (current.isEmpty) return 0;
    final compressed = await _memoryService.compressMemories(
      account: account,
      model: model,
      apiKey: apiKey,
      activeMemories: current,
      settings: settings,
    );
    if (compressed.isEmpty) return current.length;

    final now = isoNow();
    for (final entry in current) {
      entry
        ..deleted = true
        ..updatedAt = now
        ..hlc = clock.next().encode();
    }
    for (final draft in compressed.take(settings.maxMemoryEntries)) {
      repo.memories.add(
        newMemoryEntry(
          content: draft.content,
          category: draft.category,
          hlc: clock.next().encode(),
        ),
      );
    }
    settings
      ..memoryMaintenanceCycles = 0
      ..lastMemoryMaintenanceAt = now
      ..hlc = clock.next().encode();
    await repo.saveMemories();
    await repo.saveSettings();
    sync.notifyLocalChange();
    return compressed.length;
  }

  Future<({ProviderAccount account, ModelInfo model, String apiKey})?>
      _resolveModelAndKey({Conversation? conversation}) async {
    if (conversation != null) {
      final account = repo.account(conversation.accountId);
      if (account != null) {
        final key = await _secrets.apiKey(account.id);
        final model = repo.modelByModelId(account.id, conversation.modelId) ??
            defaultModelFor(account.id);
        if (key != null && key.isNotEmpty && model != null) {
          return (account: account, model: model, apiKey: key);
        }
      }
    }
    for (final account in accounts) {
      final key = await _secrets.apiKey(account.id);
      final model = defaultModelFor(account.id);
      if (key != null && key.isNotEmpty && model != null) {
        return (account: account, model: model, apiKey: key);
      }
    }
    return null;
  }

  // ---------------------------------------------------------------- settings
  Future<void> persistSettings() async {
    settings.hlc = clock.next().encode();
    await repo.saveSettings();
    sync.notifyLocalChange();
    notifyListeners();
  }

  Future<void> saveSearchKey(SearchProvider provider, String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await _secrets.deleteSearchKey(provider.name);
      _searchKeyPresence[provider] = false;
    } else {
      await _secrets.setSearchKey(provider.name, trimmed);
      _searchKeyPresence[provider] = true;
    }
    notifyListeners();
  }

  Future<void> setTheme(ThemePreference preference) async {
    settings.theme = preference;
    await persistSettings();
  }

  // -------------------------------------------------------------------- sync
  Future<void> startHosting() => sync.startHosting();
  Future<void> stopHosting() => sync.stopHosting();
  Future<String> createPairingCode() => sync.createPairingCode();
  Future<void> joinWithCode(String code) => sync.joinWithCode(code);
  Future<void> syncNow() => sync.syncNow();
  Future<void> unpair(String deviceId) => sync.unpair(deviceId);
  Future<void> reconnectPeers() => sync.reconnectPeers();

  @override
  void dispose() {
    _disposed = true;
    _cancelToken?.cancel();
    final completer = _approvalCompleter;
    if (completer != null && !completer.isCompleted) completer.complete(false);
    try {
      unawaited(sync.dispose());
    } catch (_) {
      // The controller may have failed before sync was initialized.
    }
    super.dispose();
  }
}
