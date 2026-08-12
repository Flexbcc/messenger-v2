import '../models/emergency_lock_level.dart';
import 'local_settings_store.dart';

/// Persisted emergency-lock flags (local; server revoke via AppController).
class EmergencyLockService {
  EmergencyLockService._();
  static final instance = EmergencyLockService._();

  final _store = LocalSettingsStore();

  Future<bool> areNewLoginsBlocked() =>
      _store.getBool('emergency_block_logins', false);

  Future<void> setNewLoginsBlocked(bool value) =>
      _store.setBool('emergency_block_logins', value);

  Future<bool> areNotificationsSilenced() =>
      _store.getBool('emergency_silence_notif', false);

  Future<void> setNotificationsSilenced(bool value) =>
      _store.setBool('emergency_silence_notif', value);

  Future<bool> isRecoveryLockActive() =>
      _store.getBool('emergency_recovery_lock', false);

  Future<void> setRecoveryLock(bool value) =>
      _store.setBool('emergency_recovery_lock', value);

  Future<DateTime?> lastLockAt() async {
    final raw = await _store.getString('emergency_last_lock_at', '');
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> recordLock(EmergencyLockLevel level) async {
    await _store.setString('emergency_last_lock_level', level.name);
    await _store.setString(
      'emergency_last_lock_at',
      DateTime.now().toIso8601String(),
    );
  }

  Future<String?> lastLockLevel() =>
      _store.getString('emergency_last_lock_level', '');

  Future<void> clearAllFlags() async {
    await setNewLoginsBlocked(false);
    await setNotificationsSilenced(false);
    await setRecoveryLock(false);
  }
}
