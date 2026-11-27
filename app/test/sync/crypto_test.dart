import 'dart:convert';
import 'dart:typed_data';

import 'package:astra_gui/data/sync/sync_crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pairing code is 12 unambiguous characters', () {
    final code = generatePairingCode();
    expect(code.length, 12);
    expect(RegExp(r'^[2-9A-HJ-NP-Z]{12}$').hasMatch(code), isTrue);
    expect(normalizePairingCode(' $code '), code);
    expect(normalizePairingCode('too-short'), '');
  });

  test('X25519 + HKDF produces the same pairing key', () async {
    final host = await newEphemeralKeyPair();
    final join = await newEphemeralKeyPair();
    final hostSecret = await sharedSecretBytes(
      keyPair: host.keyPair,
      remotePublicKey: join.publicKey,
    );
    final joinSecret = await sharedSecretBytes(
      keyPair: join.keyPair,
      remotePublicKey: host.publicKey,
    );
    expect(hostSecret, joinSecret);

    final salt = Uint8List.fromList([1, 2, 3, 4]);
    final hostKey = await deriveHkdf(
      inputKeyMaterial: hostSecret,
      salt: salt,
      info: 'test',
    );
    final joinKey = await deriveHkdf(
      inputKeyMaterial: joinSecret,
      salt: salt,
      info: 'test',
    );
    final box = await encryptJson({'hello': 'astra'}, key: hostKey);
    final decoded = await decryptJson(box, key: joinKey);
    expect(decoded['hello'], 'astra');
  });

  test('tampered or wrongly-keyed frames are rejected', () async {
    final key = SecretKeyData(secureRandomBytes(32));
    final other = SecretKeyData(secureRandomBytes(32));
    final box = await encryptJson({'secret': true}, key: key);
    await expectLater(
      decryptJson(box, key: other),
      throwsA(isA<SyncCryptoException>()),
    );

    final tampered = CryptoBox(
      nonce: box.nonce,
      cipherText: Uint8List.fromList([
        ...box.cipherText.sublist(0, box.cipherText.length - 1),
        box.cipherText.last ^ 1,
      ]),
      mac: box.mac,
    );
    await expectLater(
      decryptJson(tampered, key: key),
      throwsA(isA<SyncCryptoException>()),
    );
    expect(utf8.decode(base64Decode(base64Encode([1, 2]))), isNotEmpty);
  });

  test('HMAC is deterministic', () async {
    final key = SecretKeyData(secureRandomBytes(32));
    final a = await hmacBase64(key, 'hello');
    final b = await hmacBase64(key, 'hello');
    expect(a, b);
    expect(await hmacBase64(key, 'hello!'), isNot(a));
  });
}
