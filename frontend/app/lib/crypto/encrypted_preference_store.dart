import 'package:shared_preferences/shared_preferences.dart';

import '../security/device_crypto.dart';

/// Encrypts protocol-state values while retaining preference keys as indexes.
class EncryptedPreferenceStore {
  EncryptedPreferenceStore(this._prefs);

  static const _encryptedPrefix = 'enc:v1:';
  final SharedPreferences _prefs;

  Future<String?> read(String key) async {
    final stored = _prefs.getString(key);
    if (stored == null) return null;
    if (stored.startsWith(_encryptedPrefix)) {
      final clear = await DeviceCrypto.instance.decryptJson(
        stored.substring(_encryptedPrefix.length),
      );
      if (clear == null) {
        throw StateError('Encrypted protocol state failed authentication');
      }
      final value = clear['value'];
      if (value is! String) {
        throw StateError('Encrypted protocol state has an invalid shape');
      }
      return value;
    }

    // One-time migration from the former plaintext Base64 representation.
    await write(key, stored);
    return stored;
  }

  Future<void> write(String key, String value) async {
    final encrypted = await DeviceCrypto.instance.encryptJson({'value': value});
    if (!await _prefs.setString(key, '$_encryptedPrefix$encrypted')) {
      throw StateError('Unable to persist encrypted protocol state');
    }
  }

  Future<bool> contains(String key) async => await read(key) != null;
}
