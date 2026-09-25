part of 'app_controller.dart';

extension AppControllerAccountSecurityOperations on AppController {
  Future<void> loadMyProfile() async {
    final currentSession = _requireSession;
    final profile = await _profile.load();
    currentSession.displayName = profile.displayName;
    knownDisplayNames[currentSession.userId] = profile.displayName;
    phone = profile.phone;
    login = profile.login;
    email = profile.email;
    bio = profile.bio;
    profileAvatarBytes = profile.avatar;
    _notifyStateChanged();
  }

  /// Emergency Lock — see roadmap §4.
  Future<void> executeEmergencyLock(EmergencyLockLevel level) async {
    await DuressPolicyEngine.instance.handle(
      DuressTrigger.emergencyLock,
      controller: this,
      incrementCounter: false,
    );
    await EmergencyLockService.instance.recordLock(level);
    HiddenVaultSession.instance.lock();

    var remoteRevocationConfirmed = true;
    try {
      await revokeOtherDevices();
    } catch (error) {
      remoteRevocationConfirmed = false;
      DebugLog.instance.error(
        'security',
        'Emergency remote device revocation failed',
        error,
      );
    }

    if (level == EmergencyLockLevel.full ||
        level == EmergencyLockLevel.critical) {
      await EmergencyLockService.instance.setNewLoginsBlocked(true);
      await LoginApprovalService.instance.setEnabled(true);
      await notificationSettings?.silenceAllForEmergency();
      _deviceTrust.clearRuntime();
    }

    if (level == EmergencyLockLevel.critical) {
      await HiddenVaultSession.instance.wipe();
      final userId = session?.userId;
      if (userId != null) await _messageCache.clearUser(userId);
      await CryptoService.wipeLocalKeys();
      await AuthKeyPair.wipeLocal();
      crypto = null;
      authKeyPair = null;
      await EmergencyLockService.instance.setRecoveryLock(true);
    }

    await SecurityLogService.instance.append(
      SecurityEvent(
        title: 'Экстренная блокировка',
        subtitle: remoteRevocationConfirmed
            ? level.label
            : '${level.label} · удалённый отзыв устройств не подтверждён',
        at: DateTime.now(),
        icon: 'lock',
      ),
    );

    await logout();
  }

  Future<void> clearEmergencyRecoveryLock() async {
    await EmergencyLockService.instance.clearAllFlags();
    await SecurityLogService.instance.append(
      SecurityEvent(
        title: 'Блокировка восстановления снята',
        subtitle: 'Вручную',
        at: DateTime.now(),
        icon: 'lock_open',
      ),
    );
  }

  Future<void> revokeOtherDevices() async {
    final currentId = session?.deviceId;
    await _api.revokeOtherDevices();
    final toRemove = await _deviceTrust.removeOthers(currentId);
    await refreshDevices();
    await SecurityLogService.instance.append(
      SecurityEvent(
        title: 'Завершены другие сеансы',
        subtitle: 'Удалено устройств: ${toRemove.length}',
        at: DateTime.now(),
        icon: 'devices',
      ),
    );
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (!AppConfig.allowPasswordAuthBridge) {
      throw StateError('Парольная авторизация отключена');
    }
    await _api.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
  }

  NetworkUsageStore get networkUsage => _api.networkUsage;

  Future<void> updateDisplayName(String newDisplayName) async {
    final currentSession = _requireSession;
    await _profile.updateDisplayName(newDisplayName);
    currentSession.displayName = newDisplayName;
    knownDisplayNames[currentSession.userId] = newDisplayName;
    _notifyStateChanged();
  }

  Future<void> updateOwnProfile({
    required String displayName,
    required String login,
    required String phone,
    required String email,
    required String bio,
  }) async {
    final currentSession = _requireSession;
    await _profile.update(
      displayName: displayName,
      login: login,
      phone: phone,
      email: email,
      bio: bio,
    );
    currentSession.displayName = displayName;
    this.login = login.isEmpty ? null : login;
    this.phone = phone.isEmpty ? null : phone;
    this.email = email.isEmpty ? null : email;
    this.bio = bio.isEmpty ? null : bio;
    knownDisplayNames[currentSession.userId] = displayName;
    _notifyStateChanged();
  }

  Future<void> setProfileAvatar(Uint8List? bytes) async {
    await _profile.setAvatar(bytes);
    profileAvatarBytes = bytes;
    _notifyStateChanged();
  }

  Future<void> enableWebPush() async {
    if (session == null) throw StateError('Сначала войдите в аккаунт');
    if (!WebPushService.instance.isSupported) {
      throw UnsupportedError('Web Push не поддерживается этим браузером');
    }
    final key = await _api.getWebPushVapidKey();
    final subscription = await WebPushService.instance.subscribe(key);
    if (subscription == null || subscription.isEmpty) {
      throw StateError('Браузер не создал push-подписку');
    }
    await _api.registerWebPush(subscription);
  }

  Future<void> disableWebPush() async {
    if (session != null) {
      try {
        await _api.deleteWebPush();
      } catch (_) {
        // Local unsubscribe still prevents notifications in this browser.
      }
    }
    await WebPushService.instance.unsubscribe();
  }
}
