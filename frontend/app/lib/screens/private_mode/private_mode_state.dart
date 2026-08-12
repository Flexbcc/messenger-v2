import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../security/pin_security.dart';
import '../../security/private_feature_access.dart';
import '../../services/hidden_vault_session.dart';
import '../../services/privacy_preferences_store.dart';

/// State for the Private Mode / Secret Room module.
///
/// PIN hashes live in [PinSecurity] (Argon2id). Hidden chat content is
/// encrypted at rest via [HiddenVaultStore] once the vault is unlocked.
class PrivateModeState extends ChangeNotifier {
  PrivateModeState({Future<void> Function()? wipeVault})
    : _wipeVault = wipeVault ?? HiddenVaultSession.instance.wipe;

  final Future<void> Function() _wipeVault;
  bool loaded = false;
  bool isConfigured = false;
  bool hasDecoyPin = false;

  bool get canConfigureDecoyPin => isConfigured;
  bool get canUseSecretFeatures => isConfigured && hasDecoyPin;

  Future<void> load() async {
    final access = await PrivateFeatureAccess.load();
    isConfigured = access.hasPrimaryPin;
    hasDecoyPin = access.hasDecoyPin;
    loaded = true;
    notifyListeners();
  }

  Future<void> configurePins({required String realPin, String? fakePin}) async {
    await PinSecurity.saveRealPin(realPin);
    if (fakePin != null) {
      await PinSecurity.saveFakePin(fakePin);
    }
    isConfigured = true;
    hasDecoyPin = fakePin != null || await PinSecurity.hasFakePin();
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

  Future<void> reset() async {
    await PinSecurity.clearAll();
    await _wipeVault();
    await PrivacyPreferencesStore().resetPinDependentPreferences();
    isConfigured = false;
    hasDecoyPin = false;
    notifyListeners();
  }
}

enum UnlockResult { realPin, fakePin, invalid }

final privateModeStateProvider = ChangeNotifierProvider<PrivateModeState>((
  ref,
) {
  final state = PrivateModeState();
  state.load();
  return state;
});
