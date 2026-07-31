import 'package:shared_preferences/shared_preferences.dart';

import '../security/pin_security.dart';
import 'app_lock_service.dart';
import 'local_settings_store.dart';

typedef AccountScopeListener = Future<void> Function(String? userId);

/// Binds local settings + PIN storage to the logged-in account.
///
/// Without an active user, prefs use the legacy unscoped keys (login UI only).
/// With a user, every [LocalSettingsStore] / [PinSecurity] key is namespaced
/// so account B cannot inherit account A's catalog, PIN, or privacy toggles.
class AccountSettingsScope {
  AccountSettingsScope._();

  static final List<AccountScopeListener> _listeners = [];

  static void addListener(AccountScopeListener listener) {
    _listeners.add(listener);
  }

  static Future<void> _notify(String? userId) async {
    for (final listener in List<AccountScopeListener>.from(_listeners)) {
      try {
        await listener(userId);
      } catch (_) {}
    }
  }

  /// Activate storage for [userId]. Clears leftover **unscoped** catalog/PIN
  /// so old global data cannot bleed into a new empty account namespace.
  static Future<void> activate(String userId) async {
    LocalSettingsStore.setActiveUser(userId);
    PinSecurity.setActiveUser(userId);
    await LocalSettingsStore.clearUnscopedAccountData();
    await PinSecurity.clearUnscopedKeys();
    await AppLockService.instance.init();
    await _notify(userId);
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
    LocalSettingsStore.setActiveUser(userId);
    PinSecurity.setActiveUser(userId);
    await LocalSettingsStore.clearActiveUserData();
    await PinSecurity.clearAll();
    await _clearBiometricFlag(userId);
    LocalSettingsStore.setActiveUser(previous);
    PinSecurity.setActiveUser(previous);
    if (wasActive) {
      // Clearing local data does not log the user out. Keep the account scope
      // active so subsequent settings cannot leak into the legacy/global
      // namespace, then notify consumers to reload defaults.
      await AppLockService.instance.init();
      await _notify(userId);
    }
  }

  static Future<void> _clearBiometricFlag(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('private_mode_biometric_enabled_u_$userId');
    await prefs.remove('private_mode_biometric_enabled');
  }
}
