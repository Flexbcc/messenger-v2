import '../models/device_info.dart';
import 'local_settings_store.dart';

/// Login approval settings and per-device awaiting flags (local until backend sync).
class LoginApprovalService {
  LoginApprovalService._();
  static final instance = LoginApprovalService._();

  final _store = LocalSettingsStore();

  Future<bool> isEnabled() => _store.getBool('login_approval_enabled', true);

  Future<void> setEnabled(bool value) => _store.setBool('login_approval_enabled', value);

  /// Device is waiting for approval after login on this install.
  Future<bool> isDeviceAwaitingApproval(String deviceId) async {
    return _store.getBool('login_approval_await_$deviceId', false);
  }

  Future<void> markDeviceAwaitingApproval(String deviceId) async {
    await _store.setBool('login_approval_await_$deviceId', true);
  }

  Future<void> clearAwaitingApproval(String deviceId) async {
    await _store.setBool('login_approval_await_$deviceId', false);
  }

  Future<void> dismissRequest(String deviceId) async {
    final list = await _loadDismissed();
    if (!list.contains(deviceId)) {
      list.add(deviceId);
      await _store.setStringList('login_approval_dismissed', list);
    }
  }

  Future<bool> isDismissed(String deviceId) async {
    final list = await _loadDismissed();
    return list.contains(deviceId);
  }

  Future<List<String>> _loadDismissed() => _store.getStringList('login_approval_dismissed');

  bool isRecentLogin(DeviceInfo device) {
    final age = DateTime.now().difference(device.createdAt.toLocal());
    return age.inHours < 48;
  }

  Future<void> pruneDismissed(Iterable<String> activeDeviceIds) async {
    final active = activeDeviceIds.toSet();
    final list = await _loadDismissed();
    final next = list.where(active.contains).toList();
    if (next.length != list.length) {
      await _store.setStringList('login_approval_dismissed', next);
    }
  }
}
