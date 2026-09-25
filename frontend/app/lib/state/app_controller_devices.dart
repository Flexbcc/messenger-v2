part of 'app_controller.dart';

extension AppControllerDeviceOperations on AppController {
  Future<void> refreshDevices() async {
    devices = await _api.listMyDevices();
    await _syncDeviceTrustProfiles();
    await _loadDeviceSessionMeta();
    await _recordCurrentDeviceSessionMeta();
    await _scanPendingLoginApprovals();
    await LoginApprovalService.instance.pruneDismissed(
      devices.map((device) => device.id),
    );
    _notifyStateChanged();
  }

  Future<void> _loadDeviceSessionMeta() => _deviceSessions.load(devices);

  Future<void> _recordCurrentDeviceSessionMeta() {
    return _deviceSessions.captureCurrent(
      deviceId: session?.deviceId,
      websocketConnected: _realtime.isConnected,
    );
  }

  DeviceSessionMeta? sessionMetaFor(String deviceId) =>
      _deviceSessions.forDevice(deviceId);

  String connectionLabelFor(DeviceInfo device) => _deviceSessions
      .connectionLabel(device, websocketConnected: _realtime.isConnected);

  Future<void> revokeDeviceSession(String deviceId) async {
    final device = _findDevice(deviceId);
    if (device == null) return;
    if (device.isCurrent) {
      throw StateError('Нельзя завершить текущий сеанс');
    }
    try {
      await _api.revokeDevice(deviceId);
    } on ApiException catch (error) {
      if (error.statusCode != 404) rethrow;
      final others = devices.where((item) => !item.isCurrent).toList();
      if (others.length == 1 && others.first.id == deviceId) {
        await revokeOtherDevices();
        return;
      }
      rethrow;
    }
    await _deviceTrust.remove(deviceId);
    await _deviceSessions.remove(deviceId);
    devices = devices.where((item) => item.id != deviceId).toList();
    await SecurityLogService.instance.append(
      SecurityEvent(
        title: 'Сеанс завершён',
        subtitle: device.deviceName,
        at: DateTime.now(),
        icon: 'devices',
      ),
    );
    _notifyStateChanged();
  }

  Future<void> _ensureCurrentDeviceTrusted() =>
      _deviceTrust.ensureCurrentTrusted(session?.deviceId);

  Future<void> _scanPendingLoginApprovals() async {
    if (session == null) return;
    final currentId = session!.deviceId;
    final result = await _loginApprovals.refresh(
      devices: devices,
      currentDeviceTrusted: deviceTrustFor(currentId).trusted,
      isTrusted: (deviceId) => deviceTrustFor(deviceId).trusted,
    );
    if (result.newRequests.isNotEmpty) {
      InAppNotificationService.instance.notify(
        InAppNotificationEvent(
          title: 'Новый вход',
          body: 'Подтвердите вход: ${result.newRequests.first.deviceName}',
          playSound: true,
          action: InAppNotificationAction.openLoginApproval,
        ),
      );
    }
  }

  Future<void> approveLoginRequest(String deviceId) async {
    await setDeviceTrusted(deviceId, true);
    await LoginApprovalService.instance.dismissRequest(deviceId);
    await _scanPendingLoginApprovals();
    await SecurityLogService.instance.append(
      SecurityEvent(
        title: 'Вход разрешён',
        subtitle: deviceId,
        at: DateTime.now(),
        icon: 'login',
      ),
    );
    _notifyStateChanged();
  }

  Future<void> denyLoginRequest(String deviceId) async {
    final device = _findDevice(deviceId);
    if (device == null || device.isCurrent) {
      throw StateError('Нельзя отклонить неизвестное или текущее устройство');
    }
    await _api.revokeDevice(deviceId);
    await _deviceTrust.remove(deviceId);
    await _deviceSessions.remove(deviceId);
    devices = devices.where((item) => item.id != deviceId).toList();
    await LoginApprovalService.instance.dismissRequest(deviceId);
    await _scanPendingLoginApprovals();
    await SecurityLogService.instance.append(
      SecurityEvent(
        title: 'Вход отклонён',
        subtitle: deviceId,
        at: DateTime.now(),
        icon: 'login',
      ),
    );
    _notifyStateChanged();
  }

  Future<void> recheckLoginApproval() async {
    if (session == null || !loginApprovalPending) return;
    try {
      await refreshDevices();
    } on ApiException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        await _handleLoginApprovalDenied();
        return;
      }
      rethrow;
    }
    final current = _findDevice(session!.deviceId);
    if (current == null) {
      await _handleLoginApprovalDenied();
      return;
    }
    if (current.serverTrusted == true) {
      await _completeLoginApproval();
    }
    _notifyStateChanged();
  }

  Future<void> _completeLoginApproval() async {
    if (session == null) return;
    await refreshDevices();
    if (_findDevice(session!.deviceId)?.serverTrusted != true) return;
    await LoginApprovalService.instance.clearAwaitingApproval(
      session!.deviceId,
    );
    await _ensureCurrentDeviceTrusted();
    loginApprovalPending = false;
    await _startApprovedRuntime();
    _notifyStateChanged();
  }

  Future<void> _handleLoginApprovalDenied() async {
    if (session == null) return;
    loginApprovalPending = false;
    await LoginApprovalService.instance.clearAwaitingApproval(
      session!.deviceId,
    );
    await logout();
  }

  Future<void> _syncDeviceTrustProfiles() async {
    final hiddenDefault = await SettingsRuntime.instance
        .devicesHiddenAccessDefault();
    await _deviceTrust.sync(
      devices: devices,
      currentDeviceId: session?.deviceId,
      hiddenAccessDefault: hiddenDefault,
      isAwaitingApproval:
          LoginApprovalService.instance.isDeviceAwaitingApproval,
    );
  }

  DeviceInfo? _findDevice(String deviceId) {
    for (final device in devices) {
      if (device.id == deviceId) return device;
    }
    return null;
  }

  DeviceTrustProfile deviceTrustFor(String deviceId) =>
      _deviceTrust.profileFor(_findDevice(deviceId), deviceId);

  Future<void> setDeviceTrustProfile(
    String deviceId,
    DeviceTrustProfile profile, {
    bool logEvent = true,
  }) async {
    final device = _findDevice(deviceId);
    if (device == null) return;
    final next = await _deviceTrust.setFor(device, profile);
    if (logEvent) {
      await SecurityLogService.instance.append(
        SecurityEvent(
          title: 'Настройки устройства обновлены',
          subtitle:
              '${device.deviceName}: ${next.trusted ? 'доверенное' : 'недоверенное'}',
          at: DateTime.now(),
          icon: 'devices',
        ),
      );
    }
    _notifyStateChanged();
  }

  Future<void> setDeviceTrusted(String deviceId, bool trusted) async {
    final current = deviceTrustFor(deviceId);
    await _api.setDeviceTrusted(deviceId, trusted);
    await setDeviceTrustProfile(deviceId, current.copyWith(trusted: trusted));
  }

  Future<void> setDevicePrivateModeAccess(String deviceId, bool allowed) async {
    final current = deviceTrustFor(deviceId);
    await setDeviceTrustProfile(
      deviceId,
      current.copyWith(privateModeAccess: allowed),
    );
  }

  Future<void> setDeviceSecretRoomAccess(String deviceId, bool allowed) async {
    final current = deviceTrustFor(deviceId);
    await setDeviceTrustProfile(
      deviceId,
      current.copyWith(secretRoomAccess: allowed),
    );
  }

  int get trustedDeviceCount =>
      devices.where((device) => deviceTrustFor(device.id).trusted).length;
}
