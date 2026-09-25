import '../crypto/auth_keypair.dart';
import '../crypto/crypto_service.dart';
import '../security/device_crypto.dart';
import 'account_scope_id.dart';
import 'session_store.dart';

/// Portable client-only identity material. Callers must encrypt this object
/// before it leaves the device; the server never receives it.
class LocalIdentityBackup {
  LocalIdentityBackup._();

  static const _fields = <String>{
    'version',
    'user_id',
    'device_id',
    'display_name',
    'auth_seed_b64',
    'signal',
    'local_storage_key_b64',
  };
  static final RegExp _deviceIdPattern = RegExp(r'^[A-Za-z0-9._:-]+$');

  static Future<Map<String, dynamic>> export() async {
    final snapshot = await _snapshotOrNull();
    if (snapshot == null) {
      throw StateError('Локальная идентичность ещё не создана');
    }
    return snapshot;
  }

  static Future<Map<String, dynamic>?> _snapshotOrNull() async {
    final remembered = await SessionStore().loadRememberedIdentity();
    final authSeed = await AuthKeyPair.exportSeed();
    if (remembered == null && authSeed == null) return null;
    if (remembered == null || authSeed == null) {
      throw StateError('Локальная идентичность сохранена не полностью');
    }
    return {
      'version': 1,
      'user_id': remembered.userId,
      'device_id': remembered.deviceId,
      'display_name': remembered.displayName,
      'auth_seed_b64': authSeed,
      'signal': await CryptoService.exportIdentity(),
      'local_storage_key_b64': await DeviceCrypto.instance.exportKey(),
    };
  }

  static Future<void> restore(Map<String, dynamic> value) async {
    validate(value);
    final previous = await _snapshotOrNull();
    try {
      await _apply(value);
    } catch (writeError, writeStack) {
      try {
        if (previous == null) {
          await _clearImportedIdentity();
        } else {
          await _apply(previous);
        }
      } catch (_) {
        throw StateError(
          'Импорт идентичности и восстановление прежних ключей завершились ошибкой',
        );
      }
      Error.throwWithStackTrace(writeError, writeStack);
    }
  }

  static Future<void> _clearImportedIdentity() async {
    Object? firstError;
    for (final operation in <Future<void> Function()>[
      AuthKeyPair.wipeLocal,
      CryptoService.wipeLocalKeys,
      DeviceCrypto.instance.wipeLocalKey,
      SessionStore().forgetIdentity,
    ]) {
      try {
        await operation();
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) {
      throw StateError('Не удалось очистить частично импортированные ключи');
    }
  }

  static void validate(Map<String, dynamic> value) {
    if (value.length != _fields.length || !value.keys.every(_fields.contains)) {
      throw const FormatException('Некорректная структура копии ключей');
    }
    if (value['version'] is! int || value['version'] != 1) {
      throw const FormatException('Неподдерживаемая версия копии ключей');
    }
    final userId = value['user_id'];
    final deviceId = value['device_id'];
    final displayName = value['display_name'];
    final authSeed = value['auth_seed_b64'];
    final signal = value['signal'];
    final localStorageKey = value['local_storage_key_b64'];
    if (userId is! String ||
        deviceId is! String ||
        displayName is! String ||
        authSeed is! String ||
        signal is! Map<String, dynamic> ||
        localStorageKey is! String) {
      throw const FormatException('Копия ключей повреждена');
    }
    AccountScopeId.require(userId);
    if (deviceId.length > 128 || !_deviceIdPattern.hasMatch(deviceId)) {
      throw const FormatException('Некорректный идентификатор устройства');
    }
    RememberedIdentity(
      userId: userId,
      deviceId: deviceId,
      displayName: displayName,
    );
    AuthKeyPair.validateSeed(authSeed);
    CryptoService.validateIdentityBackup(signal);
    DeviceCrypto.validateEncodedKey(localStorageKey);
  }

  static Future<void> _apply(Map<String, dynamic> value) async {
    final userId = value['user_id'] as String;
    final deviceId = value['device_id'] as String;
    final displayName = value['display_name'] as String;
    final authSeed = value['auth_seed_b64'] as String;
    final signal = value['signal'] as Map<String, dynamic>;
    final localStorageKey = value['local_storage_key_b64'] as String;
    await AuthKeyPair.importSeed(authSeed);
    await CryptoService.importIdentity(signal);
    await DeviceCrypto.instance.importKey(localStorageKey);
    await SessionStore().rememberIdentity(
      userId: userId,
      deviceId: deviceId,
      displayName: displayName,
    );
  }
}
