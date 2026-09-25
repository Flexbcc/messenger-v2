import '../models/duress_policy.dart';
import '../security/pin_security.dart';
import 'local_settings_store.dart';
import 'pin_encrypted_json.dart';

class DuressPolicyFileStorage {
  DuressPolicyFileStorage._();
  static final instance = DuressPolicyFileStorage._();
  static const _key = 'duress_policy.v1';
  final _store = LocalSettingsStore();

  Future<String?> read() async {
    final value = await _store.getString(_key, '');
    return value.isEmpty ? null : value;
  }

  Future<void> write(String content) async {
    await _store.setString(_key, content);
  }

  Future<void> delete() async {
    await _store.remove(_key);
  }
}

class DuressPolicyStore {
  DuressPolicyStore._();
  static final instance = DuressPolicyStore._();

  final _storage = DuressPolicyFileStorage.instance;

  Future<DuressPolicyData?> load(String pin) async {
    final packed = await _storage.read();
    final salt = await PinSecurity.realPinSalt();
    if (salt == null) {
      if (packed != null) {
        throw StateError('Duress policy exists without a configured PIN');
      }
      return null;
    }
    if (packed == null) return null;
    final json = await PinEncryptedJson.decryptMap(
      packed: packed,
      pin: pin,
      salt: salt,
    );
    return json == null ? null : DuressPolicyData.fromJson(json);
  }

  Future<void> save(String pin, DuressPolicyData data) async {
    final salt = await PinSecurity.realPinSalt();
    if (salt == null) {
      throw StateError('Cannot save duress policy without a configured PIN');
    }
    final packed = await PinEncryptedJson.encryptMap(
      value: data.toJson(),
      pin: pin,
      salt: salt,
    );
    await _storage.write(packed);
  }

  Future<void> wipe() async => _storage.delete();
}
