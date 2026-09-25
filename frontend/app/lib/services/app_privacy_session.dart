import 'package:flutter/foundation.dart';

import '../security/pin_security.dart';

/// Runtime privacy context — decoy PIN mode vs real private mode.
class AppPrivacySession extends ChangeNotifier {
  AppPrivacySession._();
  static final instance = AppPrivacySession._();

  bool isInDecoyMode = false;

  Future<bool> isRealPinConfigured() => PinSecurity.isRealPinConfigured();

  /// Secret chat, hidden sections, etc. — only after real PIN and not in decoy mode.
  Future<bool> canAccessSecretFeatures() async {
    if (isInDecoyMode) return false;
    return PinSecurity.isRealPinConfigured();
  }

  void enterDecoyMode() {
    if (isInDecoyMode) return;
    isInDecoyMode = true;
    notifyListeners();
  }

  void enterPrivateMode() {
    if (!isInDecoyMode) return;
    isInDecoyMode = false;
    notifyListeners();
  }

  void exit() {
    if (!isInDecoyMode) return;
    isInDecoyMode = false;
    notifyListeners();
  }
}
