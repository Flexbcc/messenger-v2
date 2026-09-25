import '../models/hidden_chat.dart';
import '../security/pin_security.dart';
import 'local_settings_store.dart';
import 'pin_encrypted_json.dart';

/// Web implementation — SharedPreferences instead of dart:io File.
class VaultFileStorage {
  VaultFileStorage._();
  static final instance = VaultFileStorage._();

  static const _key = 'hidden_vault.v1';
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

/// Same API surface as IO store — used via conditional export.
class HiddenVaultStore {
  HiddenVaultStore._();
  static final instance = HiddenVaultStore._();

  final _storage = VaultFileStorage.instance;

  Future<HiddenVaultData?> load(String pin) async {
    final stored = await _storage.read();
    final salt = await PinSecurity.realPinSalt();
    if (salt == null) {
      if (stored != null) {
        throw StateError('Hidden vault exists without a configured PIN');
      }
      return HiddenVaultData();
    }
    if (stored == null || stored.isEmpty) return HiddenVaultData();

    final json = await PinEncryptedJson.decryptMap(
      packed: stored,
      pin: pin,
      salt: salt,
    );
    if (json == null) return null;
    return HiddenVaultData.fromJson(json);
  }

  Future<void> save(String pin, HiddenVaultData data) async {
    final salt = await PinSecurity.realPinSalt();
    if (salt == null) {
      throw StateError('Cannot save hidden vault without a configured PIN');
    }

    final out = await PinEncryptedJson.encryptMap(
      value: data.toJson(),
      pin: pin,
      salt: salt,
    );
    await _storage.write(out);
  }

  Future<void> wipe() async {
    await _storage.delete();
  }
}
