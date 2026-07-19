import 'package:shared_preferences/shared_preferences.dart';

import '../models/device_trust.dart';
import 'local_settings_store.dart';

/// Per-device trust profiles — local only until backend sync exists.
class DeviceTrustStore {
  final _store = LocalSettingsStore();

  Future<DeviceTrustProfile?> getProfile(String deviceId) async {
    final raw = await _store.getString('device_profile_$deviceId', '');
    if (raw.isEmpty) return null;
    return DeviceTrustProfile.decode(raw);
  }

  Future<void> setProfile(String deviceId, DeviceTrustProfile profile) async {
    await _store.setString('device_profile_$deviceId', profile.encode());
  }

  Future<void> removeProfile(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('app_settings_device_profile_$deviceId');
  }
}

Future<Map<String, DeviceTrustProfile>> loadAllDeviceTrust() async {
  final prefs = await SharedPreferences.getInstance();
  const prefix = 'app_settings_device_profile_';
  final result = <String, DeviceTrustProfile>{};
  for (final key in prefs.getKeys()) {
    if (key.startsWith(prefix)) {
      final deviceId = key.substring(prefix.length);
      final raw = prefs.getString(key);
      if (raw != null && raw.isNotEmpty) {
        result[deviceId] = DeviceTrustProfile.decode(raw);
      }
    }
  }
  return result;
}
