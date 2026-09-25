import '../config.dart';
import '../models/security_snapshot.dart';
import '../security/pin_security.dart';
import 'duress_audit_service.dart';
import 'emergency_lock_service.dart';
import 'login_approval_service.dart';
import 'privacy_preferences_store.dart';
import 'security_log_service.dart';
import 'security_meta_store.dart';

/// Builds [SecuritySnapshot] from local stores and app state inputs.
class SecuritySnapshotService {
  const SecuritySnapshotService();

  Future<SecuritySnapshot> build({
    required bool isLoggedIn,
    required bool cryptoKeysPresent,
    required bool authKeysPresent,
    required int deviceCount,
    required int trustedDeviceCount,
    required bool websocketConnected,
    required bool privateVaultUnlocked,
    required int secretHiddenChatCount,
  }) async {
    final prefs = PrivacyPreferencesStore();
    final events = await SecurityLogService.instance.load();
    final meta = SecurityMetaStore.instance;
    final lastDuress = await DuressAuditService.instance.lastOutbound();

    return SecuritySnapshot(
      pinEnabled: await PinSecurity.hasRealPin(),
      fakePinEnabled: await PinSecurity.hasFakePin(),
      appLockEnabled: await prefs.appLockEnabled(),
      secretRoomEnabled: await prefs.secretRoomEnabled(),
      hiddenChatsEnabled: await prefs.hiddenChatsEnabled(),
      loginApprovalEnabled: await LoginApprovalService.instance.isEnabled(),
      recoveryLockActive: await EmergencyLockService.instance
          .isRecoveryLockActive(),
      deviceCount: deviceCount,
      trustedDeviceCount: trustedDeviceCount,
      websocketConnected: websocketConnected,
      isLoggedIn: isLoggedIn,
      cryptoKeysPresent: cryptoKeysPresent,
      authKeysPresent: authKeysPresent,
      homeNodeUrl: AppConfig.homeNodeUrl,
      privateVaultUnlocked: privateVaultUnlocked,
      secretHiddenChatCount: secretHiddenChatCount,
      lastLoginAt: await meta.lastLoginAt(),
      lastPinChangeAt: await meta.lastPinChangeAt(),
      lastContactVerificationAt: await meta.lastContactVerificationAt(),
      lastSecurityEventTitle: events.isEmpty ? null : events.first.title,
      lastSecurityEventAt: events.isEmpty ? null : events.first.at,
      lastDuressCode: lastDuress?.code,
      lastDuressAt: lastDuress?.at,
      lastDuressChannel: lastDuress?.channel,
    );
  }
}
