/// Aggregated security posture for the dashboard screen.
/// Values reflect **local client state only** — not server-verified security.
class SecuritySnapshot {
  const SecuritySnapshot({
    required this.pinEnabled,
    required this.fakePinEnabled,
    required this.biometricEnabled,
    required this.appLockEnabled,
    required this.secretRoomEnabled,
    required this.hiddenChatsEnabled,
    required this.loginApprovalEnabled,
    required this.recoveryLockActive,
    required this.deviceCount,
    required this.trustedDeviceCount,
    required this.websocketConnected,
    required this.isLoggedIn,
    required this.cryptoKeysPresent,
    required this.authKeysPresent,
    required this.homeNodeUrl,
    required this.privateVaultUnlocked,
    required this.secretHiddenChatCount,
    this.lastLoginAt,
    this.lastPinChangeAt,
    this.lastSecurityEventTitle,
    this.lastSecurityEventAt,
    this.lastContactVerificationAt,
  });

  final bool pinEnabled;
  final bool fakePinEnabled;
  final bool biometricEnabled;
  final bool appLockEnabled;
  final bool secretRoomEnabled;
  final bool hiddenChatsEnabled;
  final bool loginApprovalEnabled;
  final bool recoveryLockActive;
  final int deviceCount;
  final int trustedDeviceCount;
  final bool websocketConnected;
  final bool isLoggedIn;
  final bool cryptoKeysPresent;
  final bool authKeysPresent;
  final String homeNodeUrl;
  final bool privateVaultUnlocked;
  final int secretHiddenChatCount;
  final DateTime? lastLoginAt;
  final DateTime? lastPinChangeAt;
  final String? lastSecurityEventTitle;
  final DateTime? lastSecurityEventAt;
  final DateTime? lastContactVerificationAt;

  /// Honest summary — never claims absolute protection.
  String get summaryTitle {
    if (recoveryLockActive) return 'Требуется восстановление';
    if (!isLoggedIn) return 'Не выполнен вход';
    if (!cryptoKeysPresent || !authKeysPresent) return 'Ключи не готовы';
    return 'Локальные проверки пройдены';
  }

  String get e2eLabel {
    if (!isLoggedIn) return 'Нет данных';
    if (!cryptoKeysPresent) return 'Ключи отсутствуют';
    return 'Локальные ключи есть';
  }

  String get secureTransportLabel => 'TLS/mTLS: не проверено клиентом';

  String get recoveryKeyLabel {
    if (recoveryLockActive) return 'Требуется (локально)';
    return 'Статус неизвестен';
  }
}
