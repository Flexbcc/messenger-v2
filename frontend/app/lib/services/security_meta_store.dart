import 'local_settings_store.dart';

/// Timestamps for security dashboard (local only).
class SecurityMetaStore {
  SecurityMetaStore._();
  static final instance = SecurityMetaStore._();

  final _store = LocalSettingsStore();

  Future<DateTime?> lastLoginAt() async {
    final ms = await _store.getInt('security_last_login_ms', 0);
    return ms == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> recordLogin() async {
    await _store.setInt(
      'security_last_login_ms',
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<DateTime?> lastPinChangeAt() async {
    final ms = await _store.getInt('security_last_pin_change_ms', 0);
    return ms == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> recordPinChange() async {
    await _store.setInt(
      'security_last_pin_change_ms',
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<DateTime?> lastContactVerificationAt() async {
    final ms = await _store.getInt('security_last_verify_ms', 0);
    return ms == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> recordContactVerification() async {
    await _store.setInt(
      'security_last_verify_ms',
      DateTime.now().millisecondsSinceEpoch,
    );
  }
}
