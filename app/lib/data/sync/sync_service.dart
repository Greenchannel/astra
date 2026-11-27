import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../util/hlc.dart';
import '../../util/ids.dart';
import '../../util/json.dart';
import '../models/models.dart';
import '../storage/app_repository.dart';
import '../storage/secret_store.dart';
import 'discovery.dart';
import 'sync_crypto.dart';

class SyncService {
  SyncService({
    required this.repository,
    required this.secrets,
    required this.clock,
    required this.onDataChanged,
    required this.onStatusChanged,
  });

  final AppRepository repository;
  final SecretStore secrets;
  final HlcClock clock;
  final void Function() onDataChanged;
  final void Function() onStatusChanged;

  final DiscoveryService _discovery = DiscoveryService();
  HttpServer? _server;
  int _serverPort = 0;
  final List<_PeerSession> _sessions = [];
  bool hosting = false;
  bool busy = false;
  String? pairingCode;
  DateTime? pairingExpiresAt;
  String? lastError;
  DateTime? lastSyncAt;
  EphemeralKeyPair? _pairKeyPair;
  Uint8List? _pairNonce;
  String? _pairingCode;
  Timer? _pairTimer;
  Timer? _broadcastTimer;
  final Map<String, List<DateTime>> _pairAttempts = {};

  String get deviceId => repository.settings.deviceId;
  String get deviceName => repository.settings.deviceName;
  int get connectedCount => _sessions.length;
  Set<String> get connectedPeerIds =>
      _sessions.map((session) => session.remoteDeviceId).toSet();
  List<PeerDevice> get peers => List.unmodifiable(repository.peers);

  void _status() => onStatusChanged();
  void _dataChanged() => onDataChanged();

  Future<void> init() async {
    if (repository.peers.any((peer) => !peer.isHost && peer.hostAddress != null)) {
      unawaited(reconnectPeers());
    }
  }

  Future<void> startHosting() async {
    if (hosting) return;
    busy = true;
    lastError = null;
    _status();
    try {
      HttpServer? server;
      var port = 0;
      for (var candidate = 41235; candidate <= 41239; candidate++) {
        try {
          server = await HttpServer.bind(
            InternetAddress.anyIPv4,
            candidate,
            shared: false,
          );
          port = candidate;
          break;
        } on SocketException {
          continue;
        }
      }
      if (server == null) {
        throw SyncException('无法监听同步端口（41235–41239 均被占用）。');
      }
      _server = server;
      _serverPort = port;
      server.listen((request) {
        unawaited(_handleRequest(request));
      });
      await _discovery.startResponder(
        hostId: deviceId,
        name: deviceName,
        platform: Platform.operatingSystem,
        syncPort: port,
      );
      hosting = true;
    } catch (error) {
      lastError = '$error';
      rethrow;
    } finally {
      busy = false;
      _status();
    }
  }

  Future<void> stopHosting() async {
    _pairTimer?.cancel();
    _pairTimer = null;
    pairingCode = null;
    pairingExpiresAt = null;
    _pairingCode = null;
    _pairKeyPair = null;
    _pairNonce = null;
    await _discovery.stopResponder();
    await _server?.close(force: true);
    _server = null;
    hosting = false;
    final sessions = _sessions.where((session) => session.isHostSide).toList();
    for (final session in sessions) {
      await session.close();
      _sessions.remove(session);
    }
    _status();
  }

  Future<String> createPairingCode() async {
    if (!hosting) await startHosting();
    final pair = await newEphemeralKeyPair();
    final nonce = secureRandomBytes(16);
    final expires = DateTime.now().add(const Duration(seconds: 120));
    _pairKeyPair = pair;
    _pairNonce = nonce;
    _pairingCode = generatePairingCode();
    pairingCode = _pairingCode;
    pairingExpiresAt = expires;
    _pairAttempts.clear();
    _discovery.setPairOffer(
      publicKey: base64Encode(pair.publicKey),
      nonce: base64Encode(nonce),
      expiresAt: expires,
    );
    _pairTimer?.cancel();
    _pairTimer = Timer(const Duration(seconds: 120), () {
      pairingCode = null;
      pairingExpiresAt = null;
      _pairingCode = null;
      _pairKeyPair = null;
      _pairNonce = null;
      _discovery.clearPairOffer();
      _status();
    });
    _status();
    return pairingCode!;
  }

  Future<void> joinWithCode(String rawCode) async {
    final code = normalizePairingCode(rawCode);
    if (code.isEmpty) {
      throw SyncException('配对码应为 12 位。');
    }
    busy = true;
    lastError = null;
    _status();
    try {
      final offers = await _discovery.discover();
      if (offers.isEmpty) {
        throw SyncException(
          '没有发现可配对的设备。请确认两端在同一 Wi-Fi，'
          '并已在对方设备上点击“生成配对码”。',
        );
      }
      Object? lastFailure;
      for (final offer in offers) {
        try {
          final peer = await _pairWithOffer(offer, code);
          await _connectToPeer(peer);
          lastError = null;
          return;
        } catch (error) {
          lastFailure = error;
        }
      }
      throw SyncException(
        lastFailure == null ? '配对失败。' : '配对失败：$lastFailure',
      );
    } catch (error) {
      lastError = '$error';
      rethrow;
    } finally {
      busy = false;
      _status();
    }
  }

  Future<void> reconnectPeers() async {
    for (final peer in List<PeerDevice>.from(repository.peers)) {
      if (peer.isHost || peer.hostAddress == null) continue;
      if (_sessions.any((session) => session.remoteDeviceId == peer.deviceId)) {
        continue;
      }
      try {
        await _connectToPeer(peer);
      } catch (error) {
        lastError = '连接 ${peer.name} 失败：$error';
      }
    }
    _status();
  }

  Future<void> syncNow() async {
    for (final session in List<_PeerSession>.from(_sessions)) {
      try {
        await _sendAllRecords(session);
      } catch (_) {
        // A dead session will be cleaned up by its receive loop.
      }
    }
    _status();
  }

  Future<void> unpair(String peerId) async {
    repository.peers.removeWhere((peer) => peer.deviceId == peerId);
    await repository.savePeers();
    await secrets.deletePeerPsk(peerId);
    for (final session in _sessions
        .where((session) => session.remoteDeviceId == peerId)
        .toList()) {
      await session.close();
      _sessions.remove(session);
    }
    _status();
    _dataChanged();
  }

  void notifyLocalChange() {
    if (_sessions.isEmpty) return;
    _broadcastTimer?.cancel();
    _broadcastTimer = Timer(const Duration(milliseconds: 650), () {
      for (final session in List<_PeerSession>.from(_sessions)) {
        unawaited(_sendAllRecords(session));
      }
    });
  }

  Future<void> dispose() async {
    _pairTimer?.cancel();
    _broadcastTimer?.cancel();
    await _discovery.stopResponder();
    for (final session in List<_PeerSession>.from(_sessions)) {
      await session.close();
    }
    _sessions.clear();
    await _server?.close(force: true);
    _server = null;
  }

  // ------------------------------------------------------------- networking
  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.uri.path != '/pair' && request.uri.path != '/sync') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.text
          ..write('Astra sync endpoint');
        await request.response.close();
        return;
      }
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final remote = request.connectionInfo?.remoteAddress.address ?? '';
      final socket = await WebSocketTransformer.upgrade(request);
      if (request.uri.path == '/pair') {
        await _handlePairSocket(socket, remote);
      } else {
        await _handleSyncSocket(socket);
      }
    } catch (error) {
      lastError = '同步服务错误：$error';
      _status();
    }
  }

  Future<void> _handlePairSocket(WebSocket socket, String remoteIp) async {
    final iterator = StreamIterator<dynamic>(socket);
    try {
      final request = await _readJson(iterator);
      if (request == null || request['t'] != 'pair_request') {
        await _writeJson(socket, {
          't': 'pair_error',
          'message': '无效的配对请求。',
        });
        return;
      }
      final pairKey = _pairKeyPair;
      final pairNonce = _pairNonce;
      final code = _pairingCode;
      final expires = pairingExpiresAt;
      if (pairKey == null ||
          pairNonce == null ||
          code == null ||
          expires == null ||
          expires.isBefore(DateTime.now())) {
        await _writeJson(socket, {
          't': 'pair_error',
          'message': '配对码已过期，请在主机上重新生成。',
        });
        return;
      }
      final attempts = _pairAttempts.putIfAbsent(remoteIp, () => []);
      attempts.removeWhere(
        (time) => DateTime.now().difference(time) > const Duration(minutes: 1),
      );
      if (attempts.length >= 10) {
        await _writeJson(socket, {
          't': 'pair_error',
          'message': '配对尝试过于频繁，请稍后再试。',
        });
        return;
      }
      attempts.add(DateTime.now());

      final joinerPublic = base64Decode(asString(request['pk']));
      final box = CryptoBox.fromJson(asMap(request['box']));
      final shared = await sharedSecretBytes(
        keyPair: pairKey.keyPair,
        remotePublicKey: Uint8List.fromList(joinerPublic),
      );
      final derived = await deriveHkdf(
        inputKeyMaterial: shared,
        salt: Uint8List.fromList([...pairNonce, ...joinerPublic]),
        info: 'astra-pair-key-v1',
      );
      final payload = await decryptJson(
        box,
        key: derived,
        aad: syncPairAad,
      );
      final supplied = normalizePairingCode(asString(payload['code']));
      final expected = code.toUpperCase();
      if (supplied.isEmpty ||
          !constantTimeEquals(utf8.encode(supplied), utf8.encode(expected))) {
        await _writeJson(socket, {
          't': 'pair_error',
          'message': '配对码不正确。',
        });
        return;
      }
      final joinerId = asString(payload['deviceId']);
      if (joinerId.isEmpty || joinerId == deviceId) {
        await _writeJson(socket, {
          't': 'pair_error',
          'message': '设备身份无效。',
        });
        return;
      }
      final psk = randomB64(32);
      await secrets.setPeerPsk(joinerId, psk);
      final existing = repository.peer(joinerId);
      if (existing == null) {
        repository.peers.add(
          PeerDevice(
            deviceId: joinerId,
            name: asString(payload['name'], '设备'),
            platform: asString(payload['platform'], 'unknown'),
            lastSeen: isoNow(),
            isHost: true,
          ),
        );
      } else {
        existing.name = asString(payload['name'], existing.name);
        existing.lastSeen = isoNow();
      }
      await repository.savePeers();
      final accept = await encryptJson(
        {
          'psk': psk,
          'hostDeviceId': deviceId,
          'hostName': deviceName,
          'hostPlatform': Platform.operatingSystem,
        },
        key: derived,
        aad: syncPairAad,
      );
      await _writeJson(socket, {
        't': 'pair_accept',
        'box': accept.toJson(),
      });
      _status();
      await Future<void>.delayed(const Duration(milliseconds: 120));
    } catch (error) {
      lastError = '配对失败：$error';
      _status();
    } finally {
      await iterator.cancel();
      await socket.close();
    }
  }

  Future<PeerDevice> _pairWithOffer(
    DiscoveredHost offer,
    String code,
  ) async {
    final pair = await newEphemeralKeyPair();
    final hostPublic = base64Decode(offer.pairPublicKey);
    final hostNonce = base64Decode(offer.pairNonce);
    final shared = await sharedSecretBytes(
      keyPair: pair.keyPair,
      remotePublicKey: Uint8List.fromList(hostPublic),
    );
    final derived = await deriveHkdf(
      inputKeyMaterial: shared,
      salt: Uint8List.fromList([...hostNonce, ...pair.publicKey]),
      info: 'astra-pair-key-v1',
    );
    final box = await encryptJson(
      {
        'code': code,
        'deviceId': deviceId,
        'name': deviceName,
        'platform': Platform.operatingSystem,
      },
      key: derived,
      aad: syncPairAad,
    );
    final socket = await WebSocket.connect(
      'ws://${offer.address}:${offer.port}/pair',
    ).timeout(const Duration(seconds: 10));
    final iterator = StreamIterator<dynamic>(socket);
    try {
      await _writeJson(socket, {
        't': 'pair_request',
        'pk': base64Encode(pair.publicKey),
        'box': box.toJson(),
      });
      final response = await _readJson(iterator);
      if (response == null) {
        throw SyncException('对方没有响应。');
      }
      if (response['t'] == 'pair_error') {
        throw SyncException(asString(response['message'], '配对失败。'));
      }
      if (response['t'] != 'pair_accept') {
        throw SyncException('配对应答无效。');
      }
      final accept = await decryptJson(
        CryptoBox.fromJson(asMap(response['box'])),
        key: derived,
        aad: syncPairAad,
      );
      final psk = asString(accept['psk']);
      final hostId = asString(accept['hostDeviceId']);
      if (psk.isEmpty || hostId.isEmpty) {
        throw SyncException('配对应答缺少必要字段。');
      }
      await secrets.setPeerPsk(hostId, psk);
      final peer = PeerDevice(
        deviceId: hostId,
        name: asString(accept['hostName'], offer.name),
        platform: asString(accept['hostPlatform'], offer.platform),
        lastSeen: isoNow(),
        isHost: false,
        hostAddress: offer.address,
        hostPort: offer.port,
      );
      repository.peers.removeWhere((item) => item.deviceId == hostId);
      repository.peers.add(peer);
      await repository.savePeers();
      _dataChanged();
      return peer;
    } finally {
      await iterator.cancel();
      await socket.close();
    }
  }

  Future<void> _handleSyncSocket(WebSocket socket) async {
    final iterator = StreamIterator<dynamic>(socket);
    try {
      final hello = await _readJson(iterator);
      if (hello == null || hello['t'] != 'hello') {
        await _writeJson(socket, {'t': 'error', 'message': '无效握手。'});
        return;
      }
      final clientDeviceId = asString(hello['deviceId']);
      final clientNonce = asString(hello['nonce']);
      final peer = repository.peer(clientDeviceId);
      final psk = await secrets.peerPsk(clientDeviceId);
      if (peer == null || psk == null || clientNonce.isEmpty) {
        await _writeJson(socket, {
          't': 'error',
          'message': '设备未配对。',
        });
        return;
      }
      final pskKey = pskFromBase64(psk);
      final serverNonce = randomB64(16);
      final serverProof = await hmacBase64(
        pskKey,
        'server|$clientDeviceId|$clientNonce|$serverNonce',
      );
      await _writeJson(socket, {
        't': 'challenge',
        'nonce': serverNonce,
        'proof': serverProof,
      });
      final proof = await _readJson(iterator);
      if (proof == null || proof['t'] != 'proof') return;
      final expected = await hmacBase64(
        pskKey,
        'client|$clientDeviceId|$clientNonce|$serverNonce',
      );
      final supplied = asString(proof['proof']);
      if (!constantTimeEquals(
        base64Decode(supplied),
        base64Decode(expected),
      )) {
        await _writeJson(socket, {'t': 'error', 'message': '认证失败。'});
        return;
      }
      final sessionKey = await deriveHkdf(
        inputKeyMaterial: Uint8List.fromList(base64Decode(psk)),
        salt: utf8.encode('$clientNonce|$serverNonce'),
        info: 'astra-sync-session-v1',
      );
      peer.lastSeen = isoNow();
      await repository.savePeers();
      await _runSession(
        socket: socket,
        iterator: iterator,
        key: sessionKey,
        remoteDeviceId: clientDeviceId,
        isHostSide: true,
      );
    } catch (error) {
      lastError = '同步握手失败：$error';
      _status();
      await iterator.cancel();
      await socket.close();
    }
  }

  Future<void> _connectToPeer(PeerDevice peer) async {
    final address = peer.hostAddress;
    if (address == null) throw SyncException('缺少主机地址。');
    final psk = await secrets.peerPsk(peer.deviceId);
    if (psk == null) throw SyncException('缺少同步密钥，请重新配对。');
    final socket = await WebSocket.connect(
      'ws://$address:${peer.hostPort}/sync',
    ).timeout(const Duration(seconds: 10));
    final iterator = StreamIterator<dynamic>(socket);
    final clientNonce = randomB64(16);
    await _writeJson(socket, {
      't': 'hello',
      'deviceId': deviceId,
      'nonce': clientNonce,
    });
    final challenge = await _readJson(iterator);
    if (challenge == null ||
        challenge['t'] == 'error' ||
        challenge['t'] != 'challenge') {
      await iterator.cancel();
      await socket.close();
      throw SyncException(
        asString(challenge?['message'], '主机拒绝连接。'),
      );
    }
    final pskKey = pskFromBase64(psk);
    final serverNonce = asString(challenge['nonce']);
    final expected = await hmacBase64(
      pskKey,
      'server|$deviceId|$clientNonce|$serverNonce',
    );
    if (!constantTimeEquals(
      base64Decode(asString(challenge['proof'])),
      base64Decode(expected),
    )) {
      await iterator.cancel();
      await socket.close();
      throw SyncException('主机身份校验失败。');
    }
    final proof = await hmacBase64(
      pskKey,
      'client|$deviceId|$clientNonce|$serverNonce',
    );
    await _writeJson(socket, {'t': 'proof', 'proof': proof});
    final sessionKey = await deriveHkdf(
      inputKeyMaterial: Uint8List.fromList(base64Decode(psk)),
      salt: utf8.encode('$clientNonce|$serverNonce'),
      info: 'astra-sync-session-v1',
    );
    peer.lastSeen = isoNow();
    await repository.savePeers();
    await _runSession(
      socket: socket,
      iterator: iterator,
      key: sessionKey,
      remoteDeviceId: peer.deviceId,
      isHostSide: false,
    );
  }

  Future<void> _runSession({
    required WebSocket socket,
    required StreamIterator<dynamic> iterator,
    required SecretKey key,
    required String remoteDeviceId,
    required bool isHostSide,
  }) async {
    final session = _PeerSession(
      socket: socket,
      key: key,
      remoteDeviceId: remoteDeviceId,
      isHostSide: isHostSide,
    );
    if (_sessions.any((item) => item.remoteDeviceId == remoteDeviceId)) {
      await session.close();
      return;
    }
    _sessions.add(session);
    lastError = null;
    _status();
    try {
      await _sendAllRecords(session);
      while (await iterator.moveNext().timeout(
        const Duration(minutes: 10),
        onTimeout: () => false,
      )) {
        final payload = await session.decode(iterator.current);
        if (payload == null) continue;
        await _handlePayload(session, payload);
      }
    } catch (error) {
      lastError = '同步中断：$error';
    } finally {
      await session.close();
      _sessions.remove(session);
      _status();
    }
  }

  // --------------------------------------------------------------- records
  List<Map<String, dynamic>> _allRecords() {
    final records = <Map<String, dynamic>>[];
    for (final account in repository.accounts) {
      records.add({
        'type': 'account',
        'id': account.id,
        'hlc': account.hlc,
        'deleted': account.deleted,
        'data': account.toJson(),
      });
    }
    for (final model in repository.models) {
      records.add({
        'type': 'model',
        'id': model.id,
        'hlc': model.hlc,
        'deleted': model.deleted,
        'data': model.toJson(),
      });
    }
    for (final conversation in repository.conversations) {
      records.add({
        'type': 'conversation',
        'id': conversation.id,
        'hlc': conversation.hlc,
        'deleted': conversation.deleted,
        'data': conversation.toJson(),
      });
    }
    for (final attachment in repository.attachments) {
      records.add({
        'type': 'attachment',
        'id': attachment.id,
        'hlc': attachment.hlc,
        'deleted': attachment.deleted,
        'data': attachment.toJson(),
      });
    }
    for (final memory in repository.memories) {
      records.add({
        'type': 'memory',
        'id': memory.id,
        'hlc': memory.hlc,
        'deleted': memory.deleted,
        'data': memory.toJson(),
      });
    }
    records.add({
      'type': 'settings',
      'id': 'settings',
      'hlc': repository.settings.hlc,
      'deleted': false,
      'data': repository.settings.toSyncJson(),
    });
    return records;
  }

  Future<void> _sendAllRecords(_PeerSession session) async {
    final records = _allRecords();
    const batchSize = 25;
    for (var start = 0; start < records.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, records.length);
      await session.send({
        't': 'records',
        'items': records.sublist(start, end),
      });
    }
  }

  Future<void> _handlePayload(
    _PeerSession session,
    Map<String, dynamic> payload,
  ) async {
    final type = asString(payload['t']);
    if (type == 'records') {
      final items = asList(payload['items']);
      final requested = <String>{};
      for (final raw in items) {
        if (raw is! Map) continue;
        final id = await _applyRecord(asMap(raw));
        if (id != null) requested.add(id);
      }
      await _saveAll();
      lastSyncAt = DateTime.now();
      _dataChanged();
      _status();
      for (final id in requested) {
        if (session.requestedAttachments.add(id)) {
          unawaited(session.send({'t': 'need_attachment', 'id': id}));
        }
      }
      return;
    }
    if (type == 'need_attachment') {
      await _sendAttachment(session, asString(payload['id']));
      return;
    }
    if (type == 'attachment_missing') {
      return;
    }
    if (type == 'attachment_start') {
      session.beginAttachment(
        asString(payload['id']),
        asMap(payload['meta']),
        asInt(payload['size']),
      );
      return;
    }
    if (type == 'attachment_chunk') {
      final ok = session.addAttachmentChunk(
        asString(payload['id']),
        asString(payload['data']),
      );
      if (!ok) {
        lastError = '图片同步数据过大或格式错误。';
        _status();
      }
      return;
    }
    if (type == 'attachment_end') {
      await _finishAttachment(session, asString(payload['id']));
      return;
    }
    if (type == 'error') {
      lastError = asString(payload['message'], '同步错误。');
      _status();
    }
  }

  Future<String?> _applyRecord(Map<String, dynamic> record) async {
    final type = asString(record['type']);
    final incomingHlc = Hlc.parse(asString(record['hlc']));
    clock.observe(incomingHlc);
    final data = asMap(record['data']);
    switch (type) {
      case 'account':
        final incoming = ProviderAccount.fromJson(data);
        final index =
            repository.accounts.indexWhere((item) => item.id == incoming.id);
        if (index < 0) {
          repository.accounts.add(incoming);
        } else if (incomingHlc.isAfter(
          Hlc.parse(repository.accounts[index].hlc),
        )) {
          repository.accounts[index] = incoming;
        }
        return null;
      case 'model':
        final incoming = ModelInfo.fromJson(data);
        final index =
            repository.models.indexWhere((item) => item.id == incoming.id);
        if (index < 0) {
          repository.models.add(incoming);
        } else if (incomingHlc.isAfter(
          Hlc.parse(repository.models[index].hlc),
        )) {
          repository.models[index] = incoming;
        }
        return null;
      case 'conversation':
        final incoming = Conversation.fromJson(data);
        final index = repository.conversations
            .indexWhere((item) => item.id == incoming.id);
        if (index < 0) {
          repository.conversations.add(incoming);
        } else {
          _mergeConversation(repository.conversations[index], incoming);
        }
        return null;
      case 'attachment':
        final incoming = Attachment.fromJson(data);
        final index = repository.attachments
            .indexWhere((item) => item.id == incoming.id);
        Attachment? local;
        if (index >= 0) {
          local = repository.attachments[index];
          final localHlc = Hlc.parse(local.hlc);
          if (incomingHlc.isAfter(localHlc) || incomingHlc == localHlc) {
            incoming.localPath = local.localPath;
            repository.attachments[index] = incoming;
          }
        } else {
          repository.attachments.add(incoming);
        }
        final effective = repository.attachment(incoming.id);
        if (effective != null &&
            !effective.deleted &&
            (effective.localPath == null ||
                !File(effective.localPath!).existsSync())) {
          return effective.id;
        }
        return null;
      case 'memory':
        final incoming = MemoryEntry.fromJson(data);
        final index =
            repository.memories.indexWhere((item) => item.id == incoming.id);
        if (index < 0) {
          repository.memories.add(incoming);
        } else if (incomingHlc.isAfter(
          Hlc.parse(repository.memories[index].hlc),
        )) {
          repository.memories[index] = incoming;
        }
        return null;
      case 'settings':
        final localHlc = Hlc.parse(repository.settings.hlc);
        if (incomingHlc.isAfter(localHlc)) {
          repository.settings.applySyncJson(data);
        }
        return null;
      default:
        return null;
    }
  }

  void _mergeConversation(Conversation local, Conversation incoming) {
    final incomingHlc = Hlc.parse(incoming.hlc);
    if (incomingHlc.isAfter(Hlc.parse(local.hlc))) {
      local
        ..title = incoming.title
        ..accountId = incoming.accountId
        ..modelId = incoming.modelId
        ..systemPrompt = incoming.systemPrompt
        ..deleted = incoming.deleted
        ..updatedAt = incoming.updatedAt
        ..hlc = incoming.hlc;
    }
    if (incoming.summaryUpdatedAt.compareTo(local.summaryUpdatedAt) > 0) {
      local
        ..contextSummary = incoming.contextSummary
        ..summarizedThroughTurnId = incoming.summarizedThroughTurnId
        ..summaryUpdatedAt = incoming.summaryUpdatedAt;
    }
    final byId = {for (final turn in local.turns) turn.id: turn};
    for (final turn in incoming.turns) {
      final existing = byId[turn.id];
      if (existing == null ||
          Hlc.parse(turn.hlc).isAfter(Hlc.parse(existing.hlc))) {
        byId[turn.id] = turn;
      }
    }
    final merged = byId.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    local.turns = merged;
    if (incoming.updatedAt.compareTo(local.updatedAt) > 0) {
      local.updatedAt = incoming.updatedAt;
    }
    if (Hlc.parse(incoming.hlc).isAfter(Hlc.parse(local.hlc))) {
      local.hlc = incoming.hlc;
    }
  }

  Future<void> _saveAll() async {
    await repository.saveAccounts();
    await repository.saveModels();
    await repository.saveConversations();
    await repository.saveAttachments();
    await repository.saveMemories();
    await repository.saveSettings();
  }

  // ------------------------------------------------------------ attachments
  Future<void> _sendAttachment(_PeerSession session, String id) async {
    final attachment = repository.attachment(id);
    if (attachment == null) {
      await session.send({'t': 'attachment_missing', 'id': id});
      return;
    }
    final bytes = await repository.readAttachment(attachment);
    if (bytes == null) {
      await session.send({'t': 'attachment_missing', 'id': id});
      return;
    }
    await session.send({
      't': 'attachment_start',
      'id': id,
      'meta': attachment.toJson(),
      'size': bytes.length,
    });
    const chunkSize = 48 * 1024;
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, bytes.length);
      await session.send({
        't': 'attachment_chunk',
        'id': id,
        'data': base64Encode(bytes.sublist(offset, end)),
      });
    }
    await session.send({'t': 'attachment_end', 'id': id});
  }

  Future<void> _finishAttachment(_PeerSession session, String id) async {
    final transfer = session.takeTransfer(id);
    if (transfer == null) return;
    final bytes = transfer.builder.takeBytes();
    final attachment = Attachment.fromJson(transfer.meta);
    if (transfer.size > 25 * 1024 * 1024) {
      lastError = '图片超过 25MB，已忽略。';
      _status();
      return;
    }
    if (attachment.sha256.isNotEmpty) {
      final digest = await Sha256().hash(bytes);
      final hash = digest.bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      if (hash != attachment.sha256) {
        lastError = '图片校验失败，已忽略。';
        _status();
        return;
      }
    }
    await repository.upsertAttachment(attachment, bytes);
    lastSyncAt = DateTime.now();
    _dataChanged();
  }

  // --------------------------------------------------------------- utilities
  Future<Map<String, dynamic>?> _readJson(
    StreamIterator<dynamic> iterator, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      if (!await iterator.moveNext().timeout(timeout)) return null;
      final raw = iterator.current;
      final text = raw is String ? raw : utf8.decode(raw as List<int>);
      final decoded = jsonDecode(text);
      return decoded is Map ? asMap(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeJson(
    WebSocket socket,
    Map<String, dynamic> payload,
  ) async {
    socket.add(jsonEncode(payload));
  }
}

class _PeerSession {
  _PeerSession({
    required this.socket,
    required this.key,
    required this.remoteDeviceId,
    required this.isHostSide,
  });

  final WebSocket socket;
  final SecretKey key;
  final String remoteDeviceId;
  final bool isHostSide;
  int _sendSeq = 0;
  int _lastRecvSeq = 0;
  bool _closed = false;
  final Set<String> requestedAttachments = <String>{};
  final Map<String, _IncomingAttachment> _transfers = {};

  Future<void> send(Map<String, dynamic> payload) async {
    if (_closed) return;
    try {
      final box = await encryptJson(payload, key: key);
      _sendSeq++;
      socket.add(jsonEncode({'s': _sendSeq, 'b': box.toJson()}));
    } catch (_) {
      await close();
    }
  }

  Future<Map<String, dynamic>?> decode(dynamic raw) async {
    try {
      final text = raw is String ? raw : utf8.decode(raw as List<int>);
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final envelope = asMap(decoded);
      final seq = asInt(envelope['s']);
      if (seq <= _lastRecvSeq) return null;
      final payload = await decryptJson(
        CryptoBox.fromJson(asMap(envelope['b'])),
        key: key,
      );
      _lastRecvSeq = seq;
      return payload;
    } catch (_) {
      return null;
    }
  }

  void beginAttachment(String id, Map<String, dynamic> meta, int size) {
    if (size < 0 || size > 25 * 1024 * 1024) return;
    _transfers[id] = _IncomingAttachment(
      meta: meta,
      size: size,
      builder: BytesBuilder(copy: false),
    );
  }

  bool addAttachmentChunk(String id, String data) {
    final transfer = _transfers[id];
    if (transfer == null) return false;
    try {
      final bytes = base64Decode(data);
      if (transfer.builder.length + bytes.length > transfer.size) {
        _transfers.remove(id);
        return false;
      }
      transfer.builder.add(bytes);
      return true;
    } catch (_) {
      _transfers.remove(id);
      return false;
    }
  }

  _IncomingAttachment? takeTransfer(String id) => _transfers.remove(id);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await socket.close();
    } catch (_) {
      // Already closed.
    }
  }
}

class _IncomingAttachment {
  _IncomingAttachment({
    required this.meta,
    required this.size,
    required this.builder,
  });

  final Map<String, dynamic> meta;
  final int size;
  final BytesBuilder builder;
}
