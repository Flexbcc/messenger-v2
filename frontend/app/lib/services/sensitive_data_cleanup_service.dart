import '../crypto/auth_keypair.dart';
import '../crypto/crypto_service.dart';
import '../security/device_crypto.dart';
import 'account_settings_scope.dart';
import 'message_cache_store.dart';
import 'persistent_media_store.dart';
import 'session_store.dart';

class SensitiveDataCleanupReport {
  const SensitiveDataCleanupReport(this.failures);

  final Map<String, Object> failures;
  bool get succeeded => failures.isEmpty;

  SensitiveDataCleanupReport merge(SensitiveDataCleanupReport other) =>
      SensitiveDataCleanupReport({...failures, ...other.failures});
}

/// Best-effort destruction across independent local storage backends.
///
/// A failure in one backend must not prevent later cryptographic keys from
/// being wiped. Callers receive the complete failure set for a visible retry.
class SensitiveDataCleanupService {
  const SensitiveDataCleanupService();

  Future<SensitiveDataCleanupReport> clearAccountData(String userId) async {
    final failures = <String, Object>{};
    await _attempt(
      failures,
      'message_cache',
      () => MessageCacheStore.instance.clearUser(userId),
    );
    await _attempt(
      failures,
      'media_store',
      () => PersistentMediaStore.instance.clearUser(userId),
    );
    await _attempt(
      failures,
      'account_settings',
      () => AccountSettingsScope.wipeUser(userId),
    );
    return SensitiveDataCleanupReport(failures);
  }

  Future<SensitiveDataCleanupReport> wipeIdentity() async {
    final failures = <String, Object>{};
    await _attempt(failures, 'signal_keys', CryptoService.wipeLocalKeys);
    await _attempt(failures, 'auth_key', AuthKeyPair.wipeLocal);
    await _attempt(
      failures,
      'local_storage_key',
      DeviceCrypto.instance.wipeLocalKey,
    );
    await _attempt(failures, 'identity_locator', SessionStore().forgetIdentity);
    return SensitiveDataCleanupReport(failures);
  }

  Future<void> _attempt(
    Map<String, Object> failures,
    String name,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (error) {
      failures[name] = error;
    }
  }
}
