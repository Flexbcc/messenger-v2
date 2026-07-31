import 'package:flutter/foundation.dart';

import '../config.dart';
import '../models/device_session_meta.dart';
import 'local_settings_store.dart';

/// Locally cached session details per device (current device updated on boot).
class DeviceSessionMetaStore {
  DeviceSessionMetaStore._();
  static final instance = DeviceSessionMetaStore._();

  final _store = LocalSettingsStore();

  Future<DeviceSessionMeta?> get(String deviceId) async {
    final raw = await _store.getString('device_session_meta_$deviceId', '');
    if (raw.isEmpty) return null;
    return DeviceSessionMeta.decode(raw);
  }

  Future<void> set(String deviceId, DeviceSessionMeta meta) async {
    await _store.setString('device_session_meta_$deviceId', meta.encode());
  }

  Future<void> remove(String deviceId) async {
    await _store.setString('device_session_meta_$deviceId', '');
  }

  /// Snapshot for this install — called after login / on resume.
  Future<DeviceSessionMeta> captureCurrent({required bool websocketConnected}) async {
    final os = defaultTargetPlatform.name;
    String? osVersion;
    if (!kIsWeb) {
      try {
        // ignore: deprecated_member_use
        osVersion = defaultTargetPlatform.name;
      } catch (_) {}
    }

    return DeviceSessionMeta(
      appVersion: '${AppInfo.version}+${AppInfo.buildNumber}',
      osName: kIsWeb ? 'Web' : os,
      osVersion: kIsWeb ? 'browser' : osVersion,
      connectionType: websocketConnected ? 'WebSocket' : 'REST',
      updatedAt: DateTime.now(),
    );
  }
}
