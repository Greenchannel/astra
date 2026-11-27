import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const syncFrameAad = 'astra-sync-frame-v1';
const syncPairAad = 'astra-pair-v1';

class SyncCryptoException implements Exception {
  SyncCryptoException(this.message);

  final String message;

  @override
  String toString() => message;
}

class CryptoBox {
  const CryptoBox({
    required this.nonce,
    required this.cipherText,
    required this.mac,
  });

  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List mac;

  Map<String, dynamic> toJson() => {
        'n': base64Encode(nonce),
        'c': base64Encode(cipherText),
        'm': base64Encode(mac),
      };

  factory CryptoBox.fromJson(Map<String, dynamic> json) => CryptoBox(
        nonce: base64Decode(json['n'] as String),
        cipherText: base64Decode(json['c'] as String),
        mac: base64Decode(json['m'] as String),
      );
}

class EphemeralKeyPair {
  const EphemeralKeyPair({required this.keyPair, required this.publicKey});

  final SimpleKeyPair keyPair;
  final Uint8List publicKey;
}

Uint8List secureRandomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

String generatePairingCode() {
  const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  final random = Random.secure();
  return List<String>.generate(
    12,
    (_) => alphabet[random.nextInt(alphabet.length)],
  ).join();
}

String normalizePairingCode(String value) {
  final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
  if (cleaned.length != 12) return '';
  return cleaned;
}

Future<EphemeralKeyPair> newEphemeralKeyPair() async {
  final algorithm = X25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  return EphemeralKeyPair(
    keyPair: keyPair,
    publicKey: Uint8List.fromList(publicKey.bytes),
  );
}

Future<Uint8List> sharedSecretBytes({
  required SimpleKeyPair keyPair,
  required Uint8List remotePublicKey,
}) async {
  final algorithm = X25519();
  final secret = await algorithm.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: SimplePublicKey(
      remotePublicKey,
      type: KeyPairType.x25519,
    ),
  );
  return Uint8List.fromList(await secret.extractBytes());
}

Future<SecretKey> deriveHkdf({
  required Uint8List inputKeyMaterial,
  required List<int> salt,
  required String info,
  int outputLength = 32,
}) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: outputLength);
  final secret = await hkdf.deriveKey(
    secretKey: SecretKey(inputKeyMaterial),
    nonce: salt,
    info: utf8.encode(info),
  );
  return secret;
}

Future<CryptoBox> encryptJson(
  Map<String, dynamic> payload, {
  required SecretKey key,
  String aad = syncFrameAad,
}) async {
  final algorithm = AesGcm.with256bits();
  final nonce = secureRandomBytes(12);
  final box = await algorithm.encrypt(
    utf8.encode(jsonEncode(payload)),
    secretKey: key,
    nonce: nonce,
    aad: utf8.encode(aad),
  );
  return CryptoBox(
    nonce: Uint8List.fromList(box.nonce),
    cipherText: Uint8List.fromList(box.cipherText),
    mac: Uint8List.fromList(box.mac.bytes),
  );
}

Future<Map<String, dynamic>> decryptJson(
  CryptoBox box, {
  required SecretKey key,
  String aad = syncFrameAad,
}) async {
  final algorithm = AesGcm.with256bits();
  try {
    final clear = await algorithm.decrypt(
      SecretBox(
        box.cipherText,
        nonce: box.nonce,
        mac: Mac(box.mac),
      ),
      secretKey: key,
      aad: utf8.encode(aad),
    );
    final decoded = jsonDecode(utf8.decode(clear));
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw SyncCryptoException('同步数据格式无效。');
  } catch (error) {
    if (error is SyncCryptoException) rethrow;
    throw SyncCryptoException('同步数据校验失败。');
  }
}

Future<String> hmacBase64(SecretKey key, String message) async {
  final mac = await Hmac.sha256().calculateMac(
    utf8.encode(message),
    secretKey: key,
  );
  return base64Encode(mac.bytes);
}

bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

SecretKey pskFromBase64(String value) =>
    SecretKey(base64Decode(value));

String randomB64(int length) => base64Encode(secureRandomBytes(length));
