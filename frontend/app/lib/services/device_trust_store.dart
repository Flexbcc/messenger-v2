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
    await _store.remove('device_profile_$deviceId');
  }
}

Future<Map<String, DeviceTrustProfile>> loadAllDeviceTrust() async {
  final entries = await LocalSettingsStore().getStringEntries(
    'device_profile_',
  );
  return {
    for (final entry in entries.entries)
      if (entry.value.isNotEmpty)
        entry.key: DeviceTrustProfile.decode(entry.value),
  };
}
