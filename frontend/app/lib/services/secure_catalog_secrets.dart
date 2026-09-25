import '../security/secure_prefs.dart';
import 'account_scope_id.dart';
import 'local_settings_store.dart';

class SecureCatalogSecrets {
  SecureCatalogSecrets._();

  static const _prefix = 'catalog_secret_v1::';
  static const _indexKey = 'secure_catalog_secret_ids_v1';
  static const _knownSecretIds = {
    'backup.password',
    'storage.s3_access_key',
    'storage.s3_secret_key',
  };
  static final RegExp _idPattern = RegExp(r'^[a-z][a-z0-9_.-]{0,127}$');

  static String _key(String settingId) {
    if (!_idPattern.hasMatch(settingId)) {
      throw ArgumentError.value(settingId, 'settingId', 'invalid setting id');
    }
    final userId = AccountScopeId.require(LocalSettingsStore.activeUserId);
    return '$_prefix$userId::$settingId';
  }

  static Future<String> read(String settingId) async {
    await _removeLegacyGlobal(settingId);
    await _removePlaintext(settingId);
    final value = await SecurePrefs.instance.read(_key(settingId)) ?? '';
    if (value.isNotEmpty) await _rememberId(settingId);
    return value;
  }

  static Future<void> write(String settingId, String value) async {
    if (value.isEmpty ||
        value.length > 4096 ||
        value.codeUnits.any((unit) => unit < 32 || unit == 127)) {
      throw const FormatException('invalid secure setting value');
    }
    await SecurePrefs.instance.write(_key(settingId), value);
    await _removeLegacyGlobal(settingId);
    await _rememberId(settingId);
    await _removePlaintext(settingId);
  }

  static Future<void> remove(String settingId) async {
    await SecurePrefs.instance.remove(_key(settingId));
    await _removeLegacyGlobal(settingId);
    final store = LocalSettingsStore();
    final ids = await store.getStringList(_indexKey)
      ..remove(settingId);
    await store.setStringList(_indexKey, ids);
    await _removePlaintext(settingId);
  }

  static Future<void> clearActiveUserSecrets() async {
    final store = LocalSettingsStore();
    final ids = {..._knownSecretIds, ...await store.getStringList(_indexKey)};
    Object? firstError;
    for (final id in ids) {
      try {
        await SecurePrefs.instance.remove(_key(id));
      } catch (error) {
        firstError ??= error;
      }
      await _removePlaintext(id);
    }
    await store.remove(_indexKey);
    if (firstError != null) {
      throw StateError('one or more secure settings could not be deleted');
    }
  }

  static Future<void> _rememberId(String settingId) async {
    final store = LocalSettingsStore();
    final ids = await store.getStringList(_indexKey);
    if (!ids.contains(settingId)) {
      await store.setStringList(_indexKey, [...ids, settingId]);
    }
  }

  static Future<void> _removePlaintext(String settingId) {
    return LocalSettingsStore().remove('catalog.$settingId');
  }

  static Future<void> _removeLegacyGlobal(String settingId) async {
    if (settingId == 'backup.password') {
      await SecurePrefs.instance.remove('backup_password_v1');
    }
  }
}
