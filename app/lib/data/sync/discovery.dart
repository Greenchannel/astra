import 'dart:async';
import 'dart:convert';
import 'dart:io';

class SyncException implements Exception {
  SyncException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DiscoveredHost {
  const DiscoveredHost({
    required this.hostId,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
    required this.pairPublicKey,
    required this.pairNonce,
    required this.pairExpiresAt,
  });

  final String hostId;
  final String name;
  final String platform;
  final String address;
  final int port;
  final String pairPublicKey;
  final String pairNonce;
  final DateTime pairExpiresAt;
}

class DiscoveryService {
  static const discoveryPort = 41234;

  RawDatagramSocket? _responder;
  String? _hostId;
  String? _name;
  String? _platform;
  int _syncPort = 0;
  String? _pairPublicKey;
  String? _pairNonce;
  DateTime? _pairExpiresAt;

  Future<void> startResponder({
    required String hostId,
    required String name,
    required String platform,
    required int syncPort,
  }) async {
    await stopResponder();
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
    );
    _responder = socket;
    _hostId = hostId;
    _name = name;
    _platform = platform;
    _syncPort = syncPort;
    socket.broadcastEnabled = true;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      try {
        final decoded = jsonDecode(utf8.decode(datagram.data));
        if (decoded is! Map || decoded['astra'] != 'probe') return;
        final expires = _pairExpiresAt;
        final offerPk = _pairPublicKey;
        final offerNonce = _pairNonce;
        if (expires == null ||
            offerPk == null ||
            offerNonce == null ||
            expires.isBefore(DateTime.now())) {
          return;
        }
        final reply = jsonEncode({
          'astra': 'offer',
          'v': 1,
          'hostId': _hostId,
          'name': _name,
          'platform': _platform,
          'port': _syncPort,
          'pairPublicKey': offerPk,
          'pairNonce': offerNonce,
          'pairExpiresAt': expires.toIso8601String(),
        });
        socket.send(
          utf8.encode(reply),
          datagram.address,
          datagram.port,
        );
      } catch (_) {
        // Ignore malformed discovery packets.
      }
    });
  }

  void setPairOffer({
    required String publicKey,
    required String nonce,
    required DateTime expiresAt,
  }) {
    _pairPublicKey = publicKey;
    _pairNonce = nonce;
    _pairExpiresAt = expiresAt;
  }

  void clearPairOffer() {
    _pairPublicKey = null;
    _pairNonce = null;
    _pairExpiresAt = null;
  }

  Future<void> stopResponder() async {
    final socket = _responder;
    _responder = null;
    _pairPublicKey = null;
    _pairNonce = null;
    _pairExpiresAt = null;
    if (socket != null) {
      try {
        socket.close();
      } catch (_) {
        // Ignore.
      }
    }
  }

  Future<List<DiscoveredHost>> discover({
    Duration timeout = const Duration(milliseconds: 1800),
  }) async {
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? subscription;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      final hosts = <String, DiscoveredHost>{};
      subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket?.receive();
        if (datagram == null) return;
        try {
          final decoded = jsonDecode(utf8.decode(datagram.data));
          if (decoded is! Map || decoded['astra'] != 'offer') return;
          final hostId = decoded['hostId'];
          final pairPublicKey = decoded['pairPublicKey'];
          final pairNonce = decoded['pairNonce'];
          final port = decoded['port'];
          final expiresAt = DateTime.tryParse(
            '${decoded['pairExpiresAt'] ?? ''}',
          );
          if (hostId is! String ||
              pairPublicKey is! String ||
              pairNonce is! String ||
              port is! int ||
              expiresAt == null ||
              expiresAt.isBefore(DateTime.now())) {
            return;
          }
          hosts[hostId] = DiscoveredHost(
            hostId: hostId,
            name: '${decoded['name'] ?? 'Astra'}',
            platform: '${decoded['platform'] ?? 'unknown'}',
            address: datagram.address.address,
            port: port,
            pairPublicKey: pairPublicKey,
            pairNonce: pairNonce,
            pairExpiresAt: expiresAt,
          );
        } catch (_) {
          // Ignore malformed replies.
        }
      });
      final probe = utf8.encode(jsonEncode({'astra': 'probe', 'v': 1}));
      socket.send(
        probe,
        InternetAddress('255.255.255.255'),
        discoveryPort,
      );
      await Future<void>.delayed(timeout);
      return hosts.values.toList(growable: false);
    } finally {
      await subscription?.cancel();
      socket?.close();
    }
  }
}
