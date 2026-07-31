import 'package:flutter/foundation.dart';

import '../security/pin_security.dart';
import 'privacy_preferences_store.dart';
import 'settings_runtime.dart';

/// Locks the whole app on resume when enabled in privacy settings.
class AppLockService extends ChangeNotifier {
  AppLockService._();
  static final instance = AppLockService._();

  bool enabled = false;
  bool lockOnBackground = true;
  bool lockOnScreenOff = true;
  bool isLocked = false;
  bool _armed = false;
  bool _forceOnResume = false;
  DateTime? _armedAt;
  int _autoLockSeconds = 60;

  Future<void> init() async {
    enabled = await PrivacyPreferencesStore().appLockEnabled();
    lockOnBackground = await PrivacyPreferencesStore().lockOnBackground();
    _autoLockSeconds = await PrivacyPreferencesStore().autoLockSeconds();
    lockOnScreenOff = await SettingsRuntime.instance.lockOnScreenOff();
    notifyListeners();
  }

  Future<void> refreshEnabled() async {
    enabled = await PrivacyPreferencesStore().appLockEnabled();
    lockOnBackground = await PrivacyPreferencesStore().lockOnBackground();
    _autoLockSeconds = await PrivacyPreferencesStore().autoLockSeconds();
    lockOnScreenOff = await SettingsRuntime.instance.lockOnScreenOff();
    if (!enabled) {
      isLocked = false;
      _armed = false;
      _armedAt = null;
      _forceOnResume = false;
    }
    notifyListeners();
  }

  /// Call when app goes to background — next resume will require PIN.
  void arm() {
    if (!enabled || !lockOnBackground || _autoLockSeconds < 0) return;
    _armed = true;
    _armedAt = DateTime.now();
    _forceOnResume = false;
  }

  /// Call on screen-off / inactive when [lockOnScreenOff] is enabled.
  void armForScreenOff() {
    if (!enabled || !lockOnScreenOff) return;
    _armed = true;
    _armedAt = DateTime.now();
    _forceOnResume = true;
  }

  /// Call on resume — lock only if we were backgrounded before.
  Future<void> onResume() async {
    if (!enabled || !_armed) return;
    final armedAt = _armedAt;
    if (!_forceOnResume &&
        _autoLockSeconds > 0 &&
        armedAt != null &&
        DateTime.now().difference(armedAt).inSeconds < _autoLockSeconds) {
      _armed = false;
      _armedAt = null;
      _forceOnResume = false;
      return;
    }
    final configured = await PinSecurity.isRealPinConfigured();
    if (!configured) return;
    isLocked = true;
    _armed = false;
    _armedAt = null;
    _forceOnResume = false;
    notifyListeners();
  }

  void unlock() {
    isLocked = false;
    notifyListeners();
  }

  Future<bool> verifyPin(String pin) async {
    return PinSecurity.verifyRealPin(pin);
  }
}
