import 'local_settings_store.dart';

/// Private Mode UI preferences — persisted locally, some affect the main app.
class PrivacyPreferencesStore {
  final _store = LocalSettingsStore();

  /// One-time migration from the legacy single `pm_app_lock` key to the new
  /// independent `pm_pin_enabled` + `pm_lock_on_background` keys.
  /// Safe to call repeatedly — is a no-op after first run.
  Future<void> migrateAppLockIfNeeded() async {
    // If new keys already exist, nothing to do.
    final pinKeyExists = (await _store.getBool('pm_pin_enabled_migrated', false));
    if (pinKeyExists) return;

    final legacyValue = await _store.getBool('pm_app_lock', false);
    if (legacyValue) {
      await _store.setBool('pm_pin_enabled', true);
      await _store.setBool('pm_lock_on_background', true);
    }
    await _store.setBool('pm_pin_enabled_migrated', true);
  }

  Future<bool> fakePinEnabled() async => _store.getBool('pm_fake_pin', false);
  Future<void> setFakePinEnabled(bool v) async => _store.setBool('pm_fake_pin', v);

  /// User finished decoy-PIN step (configured or explicitly skipped).
  Future<bool> decoyPinStepComplete() async =>
      (await fakePinEnabled()) || await _store.getBool('pm_decoy_step_done', false);
  Future<void> setDecoyPinStepComplete(bool v) async => _store.setBool('pm_decoy_step_done', v);

  Future<bool> secretRoomEnabled() async => _store.getBool('pm_secret_room', true);
  Future<void> setSecretRoomEnabled(bool v) async => _store.setBool('pm_secret_room', v);

  Future<bool> hiddenChatsEnabled() async => _store.getBool('pm_hidden_chats', true);
  Future<void> setHiddenChatsEnabled(bool v) async => _store.setBool('pm_hidden_chats', v);

  Future<bool> maskNotifications() async => _store.getBool('pm_mask_notifications', false);
  Future<void> setMaskNotifications(bool v) async => _store.setBool('pm_mask_notifications', v);

  /// Hides online status / last-seen from all peers (catalog: privacy.invisible_mode).
  Future<bool> invisibleMode() async => _store.getBool('pm_invisible_mode', false);
  Future<void> setInvisibleMode(bool v) async => _store.setBool('pm_invisible_mode', v);

  Future<bool> hidePreviews() async => _store.getBool('pm_hide_previews', false);
  Future<void> setHidePreviews(bool v) async => _store.setBool('pm_hide_previews', v);

  /// Whether PIN lock is configured / enabled (catalog: security.pin_enabled).
  Future<bool> pinEnabled() async => _store.getBool('pm_pin_enabled', false);
  Future<void> setPinEnabled(bool v) async => _store.setBool('pm_pin_enabled', v);

  /// Whether to lock the app when it goes to the background (catalog: security.lock_on_background).
  Future<bool> lockOnBackground() async => _store.getBool('pm_lock_on_background', false);
  Future<void> setLockOnBackground(bool v) async => _store.setBool('pm_lock_on_background', v);

  /// True when PIN lock is active. Equivalent to [pinEnabled].
  /// Use [lockOnBackground] separately to check the background-lock behaviour.
  Future<bool> appLockEnabled() async => pinEnabled();

  /// Legacy setter — kept for callers that haven't migrated; sets only pin_enabled.
  Future<void> setAppLockEnabled(bool v) async => setPinEnabled(v);

  Future<int> autoLockSeconds() async => _store.getInt('pm_auto_lock_sec', 60);
  Future<void> setAutoLockSeconds(int seconds) async => _store.setInt('pm_auto_lock_sec', seconds);

  Future<bool> wipeOnWrongAttempts() async => _store.getBool('pm_wipe_on_wrong', false);
  Future<void> setWipeOnWrongAttempts(bool v) async => _store.setBool('pm_wipe_on_wrong', v);

  static const autoLockLabels = {
    'Сразу': 0,
    '30 секунд': 30,
    '1 минута': 60,
    '5 минут': 300,
  };

  static String labelForSeconds(int seconds) {
    for (final e in autoLockLabels.entries) {
      if (e.value == seconds) return e.key;
    }
    return '1 минута';
  }
}
