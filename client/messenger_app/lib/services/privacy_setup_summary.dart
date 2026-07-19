import '../security/pin_security.dart';
import '../security/secret_chat_security.dart';
import 'duress_runtime_store.dart';
import 'privacy_preferences_store.dart';
import 'trusted_contacts_store.dart';

/// Read-only overview of Private Mode setup — no PIN required.
class PrivacySetupSummary {
  const PrivacySetupSummary({
    required this.hasRealPin,
    required this.hasDecoyPin,
    required this.decoyStepDone,
    required this.secretRoomConfigured,
    required this.trustedContactsCount,
    required this.hiddenChatsEnabled,
    required this.appLockEnabled,
    required this.maskNotifications,
  });

  final bool hasRealPin;
  /// Actual decoy/fake PIN stored (not just "skipped").
  final bool hasDecoyPin;
  final bool decoyStepDone;
  final bool secretRoomConfigured;
  final int trustedContactsCount;
  final bool hiddenChatsEnabled;
  final bool appLockEnabled;
  final bool maskNotifications;

  /// Secret room UI is available only after a real decoy PIN exists.
  bool get canConfigureSecretRoom => hasRealPin && hasDecoyPin;

  String get progressLabel {
    if (!hasRealPin) return 'Нужен PIN';
    if (!hasDecoyPin) return 'Нужен доп. PIN';
    if (!secretRoomConfigured) return 'Секретная комната';
    if (trustedContactsCount == 0) return 'Можно добавить доверенных';
    return 'Настроено';
  }

  static Future<PrivacySetupSummary> load() async {
    final prefs = PrivacyPreferencesStore();
    final mirror = await DuressRuntimeStore.instance.loadMirror();
    final legacyTrusted = await TrustedContactsStore.instance.load();
    final trustedIds = mirror.trustedUserIds.isNotEmpty ? mirror.trustedUserIds : legacyTrusted;
    final hasDecoy = await PinSecurity.hasFakePin();

    return PrivacySetupSummary(
      hasRealPin: await PinSecurity.isRealPinConfigured(),
      hasDecoyPin: hasDecoy,
      decoyStepDone: await prefs.decoyPinStepComplete(),
      secretRoomConfigured: await SecretChatSecurity.isConfigured(),
      trustedContactsCount: trustedIds.length,
      hiddenChatsEnabled: await prefs.hiddenChatsEnabled(),
      appLockEnabled: await prefs.appLockEnabled(),
      maskNotifications: await prefs.maskNotifications(),
    );
  }
}
