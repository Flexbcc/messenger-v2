import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../security/pin_security.dart';
import '../../services/hidden_vault_session.dart';

/// State for the Private Mode / Secret Room module.
///
/// PIN hashes live in [PinSecurity] (Argon2id). Hidden chat content is
/// encrypted at rest via [HiddenVaultStore] once the vault is unlocked.
class PrivateModeState extends ChangeNotifier {
  static const _biometricKey = 'private_mode_biometric_enabled';

  bool biometricEnabled = false;
  bool loaded = false;
  bool isConfigured = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    biometricEnabled = prefs.getBool(_biometricKey) ?? false;
    isConfigured = await PinSecurity.isRealPinConfigured();
    loaded = true;
    notifyListeners();
  }

  Future<void> configurePins({required String realPin, String? fakePin}) async {
    await PinSecurity.saveRealPin(realPin);
    if (fakePin != null) {
      await PinSecurity.saveFakePin(fakePin);
    }
    isConfigured = true;
    notifyListeners();
  }

  Future<UnlockResult> evaluate(String pin) async {
    final result = await PinSecurity.evaluatePin(pin);
    return switch (result) {
      PinUnlockResult.realPin => UnlockResult.realPin,
      PinUnlockResult.fakePin => UnlockResult.fakePin,
      PinUnlockResult.invalid => UnlockResult.invalid,
    };
  }

  Future<void> setBiometricEnabled(bool enabled) async {
    biometricEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_biometricKey, enabled);
    notifyListeners();
  }

  Future<void> reset() async {
    await PinSecurity.clearAll();
    await HiddenVaultSession.instance.wipe();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_biometricKey);
    biometricEnabled = false;
    isConfigured = false;
    notifyListeners();
  }
}

enum UnlockResult { realPin, fakePin, invalid }

final privateModeStateProvider = ChangeNotifierProvider<PrivateModeState>((ref) {
  final state = PrivateModeState();
  state.load();
  return state;
});
