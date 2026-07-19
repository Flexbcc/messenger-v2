import 'package:flutter/foundation.dart';

import '../security/pin_security.dart';
import 'privacy_preferences_store.dart';

/// Locks the whole app on resume / idle when enabled in privacy settings.
class AppLockService extends ChangeNotifier {
  AppLockService._();
  static final instance = AppLockService._();

  bool enabled = false;
  bool isLocked = false;
  bool _armed = false;
  DateTime? _lastForegroundAt;
  int _autoLockSeconds = 60;
  DateTime? _forcedUntil;

  Future<void> init() async {
    final prefs = PrivacyPreferencesStore();
    enabled = await prefs.appLockEnabled();
    _autoLockSeconds = await prefs.autoLockSeconds();
    _lastForegroundAt = DateTime.now();
    notifyListeners();
  }

  Future<void> refreshEnabled() async {
    final prefs = PrivacyPreferencesStore();
    enabled = await prefs.appLockEnabled();
    _autoLockSeconds = await prefs.autoLockSeconds();
    if (!enabled) {
      isLocked = false;
      _armed = false;
      _forcedUntil = null;
    }
    notifyListeners();
  }

  Future<void> refreshAutoLockSeconds() async {
    _autoLockSeconds = await PrivacyPreferencesStore().autoLockSeconds();
  }

  /// Call when app goes to background — next resume may require PIN.
  void arm() {
    if (!enabled) return;
    _armed = true;
  }

  /// Call on resume — lock if backgrounded or idle timeout exceeded.
  Future<void> onResume() async {
    if (!enabled) return;
    final configured = await PinSecurity.isRealPinConfigured();
    if (!configured) return;

    final now = DateTime.now();
    final forced = _forcedUntil != null && now.isBefore(_forcedUntil!);
    final idle = _lastForegroundAt != null &&
        _autoLockSeconds > 0 &&
        now.difference(_lastForegroundAt!).inSeconds >= _autoLockSeconds;

    if (_armed || forced || idle) {
      isLocked = true;
      notifyListeners();
    }
    _armed = false;
    _lastForegroundAt = now;
  }

  /// Mark active use (resets idle clock).
  void noteUserActivity() {
    _lastForegroundAt = DateTime.now();
  }

  /// Force lock from a duress `lockApp` action.
  void lockNow({Duration? duration}) {
    isLocked = true;
    if (duration != null) {
      _forcedUntil = DateTime.now().add(duration);
    }
    notifyListeners();
  }

  void unlock() {
    isLocked = false;
    _forcedUntil = null;
    _lastForegroundAt = DateTime.now();
    notifyListeners();
  }

  Future<PinUnlockResult> evaluatePin(String pin) => PinSecurity.evaluatePin(pin);

  Future<bool> verifyPin(String pin) async {
    return PinSecurity.verifyRealPin(pin);
  }
}
