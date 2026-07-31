import '../crypto/auth_keypair.dart';
import '../crypto/crypto_service.dart';
import '../security/device_crypto.dart';
import 'session_store.dart';

/// Portable client-only identity material. Callers must encrypt this object
/// before it leaves the device; the server never receives it.
class LocalIdentityBackup {
  LocalIdentityBackup._();

  static Future<Map<String, dynamic>> export() async {
    final remembered = await SessionStore().loadRememberedIdentity();
    final authSeed = await AuthKeyPair.exportSeed();
    if (remembered == null || authSeed == null) {
      throw StateError('Локальная идентичность ещё не создана');
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
    if (value['version'] != 1) {
      throw const FormatException('Неподдерживаемая версия копии ключей');
    }
    final userId = value['user_id'] as String?;
    final deviceId = value['device_id'] as String?;
    final displayName = value['display_name'] as String?;
    final authSeed = value['auth_seed_b64'] as String?;
    final signal = value['signal'];
    final localStorageKey = value['local_storage_key_b64'] as String?;
    if (userId == null ||
        deviceId == null ||
        displayName == null ||
        authSeed == null ||
        signal is! Map<String, dynamic> ||
        localStorageKey == null) {
      throw const FormatException('Копия ключей повреждена');
    }
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
