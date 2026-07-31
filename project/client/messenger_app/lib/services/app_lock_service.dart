import 'package:flutter/foundation.dart';

import '../security/pin_security.dart';
import 'privacy_preferences_store.dart';
import 'settings_runtime.dart';

/// Locks the whole app on resume when enabled in privacy settings.
class AppLockService extends ChangeNotifier {
  AppLockService._();
  static final instance = AppLockService._();

  bool enabled = false;
  bool lockOnScreenOff = true;
  bool isLocked = false;
  bool _armed = false;

  Future<void> init() async {
    enabled = await PrivacyPreferencesStore().appLockEnabled();
    lockOnScreenOff = await SettingsRuntime.instance.lockOnScreenOff();
    notifyListeners();
  }

  Future<void> refreshEnabled() async {
    enabled = await PrivacyPreferencesStore().appLockEnabled();
    lockOnScreenOff = await SettingsRuntime.instance.lockOnScreenOff();
    if (!enabled) {
      isLocked = false;
      _armed = false;
    }
    notifyListeners();
  }

  /// Call when app goes to background — next resume will require PIN.
  void arm() {
    if (!enabled) return;
    _armed = true;
  }

  /// Call on screen-off / inactive when [lockOnScreenOff] is enabled.
  void armForScreenOff() {
    if (!enabled || !lockOnScreenOff) return;
    _armed = true;
  }

  /// Call on resume — lock only if we were backgrounded before.
  Future<void> onResume() async {
    if (!enabled || !_armed) return;
    final configured = await PinSecurity.isRealPinConfigured();
    if (!configured) return;
    isLocked = true;
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
