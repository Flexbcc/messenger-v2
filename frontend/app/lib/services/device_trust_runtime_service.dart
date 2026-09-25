import '../models/device_info.dart';
import '../models/device_trust.dart';
import 'device_trust_store.dart';

typedef DeviceAwaitingApproval = Future<bool> Function(String deviceId);

/// Owns account-scoped device trust state and enforces its invariants.
class DeviceTrustRuntimeService {
  DeviceTrustRuntimeService({DeviceTrustStore? store})
    : _store = store ?? DeviceTrustStore();

  final DeviceTrustStore _store;
  Map<String, DeviceTrustProfile> _profiles = {};

  Map<String, DeviceTrustProfile> get profiles => Map.unmodifiable(_profiles);

  Future<void> load() async {
    _profiles = await loadAllDeviceTrust();
  }

  void clearRuntime() {
    _profiles = {};
  }

  DeviceTrustProfile profileFor(DeviceInfo? device, String deviceId) {
    if (device?.isCurrent == true) {
      return _profiles[deviceId] ?? DeviceTrustProfile.currentDevice;
    }
    return _profiles[deviceId] ?? DeviceTrustProfile.unknown;
  }

  Future<DeviceTrustProfile> setFor(
    DeviceInfo device,
    DeviceTrustProfile profile,
  ) async {
    var next = device.isCurrent ? profile.copyWith(trusted: true) : profile;
    if (!next.trusted) {
      next = next.copyWith(privateModeAccess: false, secretRoomAccess: false);
    }
    await _persist(device.id, next);
    return next;
  }

  Future<void> _persist(String deviceId, DeviceTrustProfile profile) async {
    await _store.setProfile(deviceId, profile);
    _profiles[deviceId] = profile;
  }

  Future<void> remove(String deviceId) async {
    await _store.removeProfile(deviceId);
    _profiles.remove(deviceId);
  }

  Future<List<String>> removeOthers(String? currentDeviceId) async {
    final ids = _profiles.keys
        .where((id) => id != currentDeviceId)
        .toList(growable: false);
    for (final id in ids) {
      await remove(id);
    }
    return ids;
  }

  Future<void> ensureCurrentTrusted(String? currentDeviceId) async {
    if (currentDeviceId == null) return;
    final current = _profiles[currentDeviceId];
    if (current == null || !current.trusted) {
      final next = (current ?? DeviceTrustProfile.currentDevice).copyWith(
        trusted: true,
      );
      await _store.setProfile(currentDeviceId, next);
      _profiles[currentDeviceId] = next;
    }
  }

  Future<void> sync({
    required List<DeviceInfo> devices,
    required String? currentDeviceId,
    required bool hiddenAccessDefault,
    required DeviceAwaitingApproval isAwaitingApproval,
  }) async {
    final knownIds = devices.map((device) => device.id).toSet();
    final removed = _profiles.keys
        .where((id) => !knownIds.contains(id))
        .toList(growable: false);
    for (final id in removed) {
      await remove(id);
    }

    for (final device in devices) {
      final awaiting = await isAwaitingApproval(device.id);
      final existing = _profiles[device.id];
      final trusted = device.serverTrusted && !awaiting;
      if (existing != null && existing.trusted == trusted) {
        continue;
      }
      if (existing != null) {
        await _persist(
          device.id,
          existing.copyWith(
            trusted: trusted,
            privateModeAccess: trusted && existing.privateModeAccess,
            secretRoomAccess: trusted && existing.secretRoomAccess,
          ),
        );
        continue;
      }
      await _persist(
        device.id,
        DeviceTrustProfile(
          trusted: trusted,
          privateModeAccess: trusted && hiddenAccessDefault,
          secretRoomAccess: trusted && hiddenAccessDefault,
        ),
      );
    }

    if (currentDeviceId != null &&
        _profiles.containsKey(currentDeviceId) &&
        devices.any(
          (device) => device.id == currentDeviceId && device.serverTrusted,
        ) &&
        !await isAwaitingApproval(currentDeviceId)) {
      await ensureCurrentTrusted(currentDeviceId);
    }
  }
}
