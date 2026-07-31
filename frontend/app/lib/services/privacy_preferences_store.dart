import 'local_settings_store.dart';

/// Private Mode UI preferences — persisted locally, some affect the main app.
class PrivacyPreferencesStore {
  final _store = LocalSettingsStore();

  Future<bool> fakePinEnabled() async => _store.getBool('pm_fake_pin', false);
  Future<void> setFakePinEnabled(bool v) async =>
      _store.setBool('pm_fake_pin', v);

  /// User finished decoy-PIN step (configured or explicitly skipped).
  Future<bool> decoyPinStepComplete() async =>
      (await fakePinEnabled()) ||
      await _store.getBool('pm_decoy_step_done', false);
  Future<void> setDecoyPinStepComplete(bool v) async =>
      _store.setBool('pm_decoy_step_done', v);

  Future<bool> secretRoomEnabled() async =>
      _store.getBool('pm_secret_room', true);
  Future<void> setSecretRoomEnabled(bool v) async =>
      _store.setBool('pm_secret_room', v);

  Future<bool> hiddenChatsEnabled() async =>
      _store.getBool('pm_hidden_chats', true);
  Future<void> setHiddenChatsEnabled(bool v) async =>
      _store.setBool('pm_hidden_chats', v);

  Future<bool> maskNotifications() async =>
      _store.getBool('pm_mask_notifications', false);
  Future<void> setMaskNotifications(bool v) async =>
      _store.setBool('pm_mask_notifications', v);

  Future<bool> hidePreviews() async =>
      _store.getBool('pm_hide_previews', false);
  Future<void> setHidePreviews(bool v) async =>
      _store.setBool('pm_hide_previews', v);

  Future<bool> appLockEnabled() async => _store.getBool('pm_app_lock', false);
  Future<void> setAppLockEnabled(bool v) async =>
      _store.setBool('pm_app_lock', v);

  Future<bool> lockOnBackground() async =>
      _store.getBool('pm_lock_on_background', true);
  Future<void> setLockOnBackground(bool v) async =>
      _store.setBool('pm_lock_on_background', v);

  Future<int> autoLockSeconds() async => _store.getInt('pm_auto_lock_sec', 60);
  Future<void> setAutoLockSeconds(int seconds) async =>
      _store.setInt('pm_auto_lock_sec', seconds);

  Future<bool> wipeOnWrongAttempts() async =>
      _store.getBool('pm_wipe_on_wrong', false);
  Future<void> setWipeOnWrongAttempts(bool v) async =>
      _store.setBool('pm_wipe_on_wrong', v);

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
