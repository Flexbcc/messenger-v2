import '../models/device_info.dart';
import '../models/device_session_meta.dart';
import '../utils/format.dart';
import 'device_session_meta_store.dart';

/// Owns locally cached metadata for the account's device sessions.
class DeviceSessionRuntimeService {
  DeviceSessionRuntimeService({DeviceSessionMetaStore? store})
    : _store = store ?? DeviceSessionMetaStore.instance;

  final DeviceSessionMetaStore _store;
  final Map<String, DeviceSessionMeta> _metadata = {};

  Map<String, DeviceSessionMeta> get metadata => Map.unmodifiable(_metadata);

  void clearRuntime() => _metadata.clear();

  Future<void> load(Iterable<DeviceInfo> devices) async {
    _metadata.clear();
    for (final device in devices) {
      final meta = await _store.get(device.id);
      if (meta != null) _metadata[device.id] = meta;
    }
  }

  Future<void> captureCurrent({
    required String? deviceId,
    required bool websocketConnected,
  }) async {
    if (deviceId == null) return;
    final meta = await _store.captureCurrent(
      websocketConnected: websocketConnected,
    );
    _metadata[deviceId] = meta;
    await _store.set(deviceId, meta);
  }

  DeviceSessionMeta? forDevice(String deviceId) => _metadata[deviceId];

  Future<void> remove(String deviceId) async {
    _metadata.remove(deviceId);
    await _store.remove(deviceId);
  }

  String connectionLabel(
    DeviceInfo device, {
    required bool websocketConnected,
  }) {
    if (device.isCurrent) {
      return websocketConnected ? 'WebSocket · активно' : 'REST · ожидание WS';
    }
    if (isDeviceOnline(device)) return 'Недавняя активность';
    return 'Не в сети';
  }
}
