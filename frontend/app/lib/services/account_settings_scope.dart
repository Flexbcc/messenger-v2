import 'package:shared_preferences/shared_preferences.dart';

import '../security/pin_security.dart';
import '../security/secret_chat_security.dart';
import 'app_lock_service.dart';
import 'debug_log.dart';
import 'local_settings_store.dart';
import 'ppc/ppc_vault.dart';
import 'secure_catalog_secrets.dart';

typedef AccountScopeListener = Future<void> Function(String? userId);

/// Binds local settings + PIN storage to the logged-in account.
///
/// Without an active user, non-sensitive login UI preferences may use legacy
/// unscoped keys; PIN operations fail closed. With a user, every
/// [LocalSettingsStore] / [PinSecurity] key is namespaced
/// so account B cannot inherit account A's catalog, PIN, or privacy toggles.
class AccountSettingsScope {
  AccountSettingsScope._();

  static final List<AccountScopeListener> _listeners = [];

  static void addListener(AccountScopeListener listener) {
    _listeners.add(listener);
  }

  static Future<void> _notify(String? userId) async {
    Object? firstError;
    for (final listener in List<AccountScopeListener>.from(_listeners)) {
      try {
        await listener(userId);
      } catch (error) {
        firstError ??= error;
        DebugLog.instance.error(
          'account-scope',
          'Account-scoped listener failed',
          error,
        );
      }
    }
    if (firstError != null) {
      throw StateError('Account-scoped state could not be fully reloaded');
    }
  }

  /// Activate storage for [userId]. Clears leftover **unscoped** catalog/PIN
  /// so old global data cannot bleed into a new empty account namespace.
  static Future<void> activate(String userId) async {
    final previous = LocalSettingsStore.activeUserId;
    LocalSettingsStore.setActiveUser(userId);
    PinSecurity.setActiveUser(userId);
    try {
      await LocalSettingsStore.clearUnscopedAccountData();
      await PinSecurity.clearUnscopedKeys();
      await SecretChatSecurity.clearLegacyUnscopedKeys();
      await PpcVault.clearLegacyUnscopedKeys();
      await AppLockService.instance.init();
      await _notify(userId);
    } catch (error) {
      // Scope changes are security boundaries. Never leave consumers partly
      // attached to a new account when one of them failed to reload.
      LocalSettingsStore.setActiveUser(previous);
      PinSecurity.setActiveUser(previous);
      try {
        await AppLockService.instance.init();
        await _notify(previous);
      } catch (rollbackError) {
        DebugLog.instance.error(
          'account-scope',
          'Account-scope rollback failed',
          rollbackError,
        );
      }
      rethrow;
    }
  }

  /// Leave account scope. Keeps namespaced data for the next login of that user.
  static Future<void> deactivate() async {
    LocalSettingsStore.setActiveUser(null);
    PinSecurity.setActiveUser(null);
    await AppLockService.instance.init();
    await _notify(null);
  }

  /// Permanently wipe settings + PIN for [userId] (delete profile / clear data).
  static Future<void> wipeUser(String userId) async {
    final previous = LocalSettingsStore.activeUserId;
    final wasActive = previous == userId;
    Object? wipeError;
    StackTrace? wipeStackTrace;
    try {
      LocalSettingsStore.setActiveUser(userId);
      PinSecurity.setActiveUser(userId);
      await SecureCatalogSecrets.clearActiveUserSecrets();
      await LocalSettingsStore.clearActiveUserData();
      await PinSecurity.clearAll();
      await SecretChatSecurity.clearPassword();
      await PpcVault(userId: userId).clear();
      await _clearBiometricFlag(userId);
    } catch (error, stackTrace) {
      wipeError = error;
      wipeStackTrace = stackTrace;
    } finally {
      // The temporary scope is process-global. Always restore it, including
      // after a partial secure-storage failure.
      LocalSettingsStore.setActiveUser(previous);
      PinSecurity.setActiveUser(previous);
    }

    if (wasActive) {
      try {
        // Clearing local data does not log the user out. Keep the account
        // scope active and reload defaults, even after a partial wipe.
        await AppLockService.instance.init();
        await _notify(userId);
      } catch (reloadError, reloadStackTrace) {
        if (wipeError == null) {
          Error.throwWithStackTrace(reloadError, reloadStackTrace);
        }
        DebugLog.instance.error(
          'account-scope',
          'Account state reload after partial wipe failed',
          reloadError,
        );
      }
    }
    if (wipeError != null) {
      Error.throwWithStackTrace(wipeError, wipeStackTrace!);
    }
  }

  static Future<void> _clearBiometricFlag(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in [
      'private_mode_biometric_enabled_u_$userId',
      'private_mode_biometric_enabled',
    ]) {
      if (prefs.containsKey(key) && !await prefs.remove(key)) {
        throw StateError('Unable to clear private-mode biometric state');
      }
    }
  }
}
