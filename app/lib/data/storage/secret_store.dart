import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// All secrets live here (Keychain / Keystore / DPAPI / libsecret).
///
/// Nothing in this class is ever serialized into app JSON or sync records.
class SecretStore {
  SecretStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _prefix = 'astra/';

  String _accountKey(String accountId) => '${_prefix}account/$accountId/key';
  String _searchKey(String provider) => '${_prefix}search/$provider/key';
  String _peerKey(String deviceId) => '${_prefix}sync/peer/$deviceId/psk';

  Future<String?> apiKey(String accountId) =>
      _storage.read(key: _accountKey(accountId));

  Future<void> setApiKey(String accountId, String value) =>
      _storage.write(key: _accountKey(accountId), value: value);

  Future<void> deleteApiKey(String accountId) =>
      _storage.delete(key: _accountKey(accountId));

  Future<String?> searchKey(String provider) =>
      _storage.read(key: _searchKey(provider));

  Future<void> setSearchKey(String provider, String value) =>
      _storage.write(key: _searchKey(provider), value: value);

  Future<void> deleteSearchKey(String provider) =>
      _storage.delete(key: _searchKey(provider));

  Future<String?> peerPsk(String deviceId) =>
      _storage.read(key: _peerKey(deviceId));

  Future<void> setPeerPsk(String deviceId, String psk) =>
      _storage.write(key: _peerKey(deviceId), value: psk);

  Future<void> deletePeerPsk(String deviceId) =>
      _storage.delete(key: _peerKey(deviceId));
}
