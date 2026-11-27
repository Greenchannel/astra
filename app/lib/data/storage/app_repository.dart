import 'dart:io';
import 'dart:typed_data';

import '../../util/ids.dart';
import '../../util/json.dart';
import '../models/models.dart';
import 'app_paths.dart';
import 'json_store.dart';

class AppRepository {
  AppRepository({JsonStore? store, AppPaths? paths})
      : _store = store,
        _paths = paths;

  JsonStore? _store;
  AppPaths? _paths;

  AppPaths get paths => _paths!;
  JsonStore get store => _store!;

  AppSettings settings = AppSettings.defaults(
    deviceId: 'pending',
    deviceName: 'Astra',
  );
  List<ProviderAccount> accounts = [];
  List<ModelInfo> models = [];
  List<Conversation> conversations = [];
  List<Attachment> attachments = [];
  List<MemoryEntry> memories = [];
  List<PeerDevice> peers = [];

  Future<void> init() async {
    _paths ??= await AppPaths.open();
    _store ??= JsonStore(paths.root);

    final settingsRaw = await store.read('settings.json');
    if (settingsRaw is Map) {
      settings = AppSettings.fromJson(
        asMap(settingsRaw),
        newId('device'),
      );
    } else {
      settings = AppSettings.defaults(
        deviceId: newId('device'),
        deviceName: '${Platform.operatingSystem} 上的 Astra',
      );
    }

    accounts = asMapList(await store.read('accounts.json'))
        .map(ProviderAccount.fromJson)
        .toList();
    models =
        asMapList(await store.read('models.json')).map(ModelInfo.fromJson).toList();
    conversations = asMapList(await store.read('conversations.json'))
        .map(Conversation.fromJson)
        .toList();
    attachments = asMapList(await store.read('attachments.json'))
        .map(Attachment.fromJson)
        .toList();
    memories = asMapList(await store.read('memories.json'))
        .map(MemoryEntry.fromJson)
        .toList();
    peers =
        asMapList(await store.read('peers.json')).map(PeerDevice.fromJson).toList();

    for (final attachment in attachments) {
      final file = File(paths.attachmentPath(attachment.id, attachment.extension));
      if (await file.exists()) {
        attachment.localPath = file.path;
      }
    }
  }

  List<Conversation> get visibleConversations {
    final list = conversations.where((item) => !item.deleted).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  Conversation? conversation(String id) {
    for (final item in conversations) {
      if (item.id == id && !item.deleted) return item;
    }
    return null;
  }

  ProviderAccount? account(String id) {
    for (final item in accounts) {
      if (item.id == id && !item.deleted) return item;
    }
    return null;
  }

  List<ProviderAccount> get visibleAccounts =>
      accounts.where((item) => !item.deleted).toList();

  List<ModelInfo> modelsFor(String accountId, {bool enabledOnly = false}) {
    final list = models
        .where(
          (item) =>
              !item.deleted &&
              item.accountId == accountId &&
              (!enabledOnly || item.enabled),
        )
        .toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    return list;
  }

  ModelInfo? modelByRowId(String id) {
    for (final item in models) {
      if (item.id == id && !item.deleted) return item;
    }
    return null;
  }

  ModelInfo? modelByModelId(String accountId, String modelId) {
    for (final item in models) {
      if (!item.deleted &&
          item.accountId == accountId &&
          item.modelId == modelId) {
        return item;
      }
    }
    return null;
  }

  Attachment? attachment(String id) {
    for (final item in attachments) {
      if (item.id == id && !item.deleted) return item;
    }
    return null;
  }

  List<MemoryEntry> get visibleMemories {
    final list = memories.where((item) => !item.deleted).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  MemoryEntry? memory(String id) {
    for (final item in memories) {
      if (item.id == id && !item.deleted) return item;
    }
    return null;
  }

  PeerDevice? peer(String deviceId) {
    for (final item in peers) {
      if (item.deviceId == deviceId) return item;
    }
    return null;
  }

  Future<void> saveSettings() => store.write('settings.json', settings.toJson());

  Future<void> saveAccounts() => store.write(
        'accounts.json',
        accounts.map((item) => item.toJson()).toList(),
      );

  Future<void> saveModels() => store.write(
        'models.json',
        models.map((item) => item.toJson()).toList(),
      );

  Future<void> saveConversations() => store.write(
        'conversations.json',
        conversations.map((item) => item.toJson()).toList(),
      );

  Future<void> saveAttachments() => store.write(
        'attachments.json',
        attachments
            .map((item) => item.toJson(includeLocalPath: false))
            .toList(),
      );

  Future<void> saveMemories() => store.write(
        'memories.json',
        memories.map((item) => item.toJson()).toList(),
      );

  Future<void> savePeers() => store.write(
        'peers.json',
        peers.map((item) => item.toJson()).toList(),
      );

  Future<void> upsertAttachment(Attachment attachment, Uint8List bytes) async {
    final path = paths.attachmentPath(attachment.id, attachment.extension);
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    attachment.localPath = path;
    final index = attachments.indexWhere((item) => item.id == attachment.id);
    if (index >= 0) {
      attachments[index] = attachment;
    } else {
      attachments.add(attachment);
    }
    await saveAttachments();
  }

  Future<Uint8List?> readAttachment(Attachment attachment) async {
    final path = attachment.localPath;
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  Future<void> deleteAttachment(String id) async {
    final attachment = this.attachment(id);
    if (attachment == null) return;
    attachment.deleted = true;
    if (attachment.localPath != null) {
      try {
        await File(attachment.localPath!).delete();
      } catch (_) {
        // File may already be gone.
      }
    }
    await saveAttachments();
  }
}
