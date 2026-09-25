import 'model_parsing.dart';

class DeviceInfo {
  DeviceInfo({
    required this.id,
    required this.deviceName,
    required this.deviceType,
    required this.createdAt,
    required this.lastActive,
    required this.isCurrent,
    required this.serverTrusted,
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    final isCurrent = json['is_current'];
    final serverTrusted = json['trusted'];
    if (isCurrent is! bool || serverTrusted is! bool) {
      throw const FormatException('invalid device flags');
    }
    return DeviceInfo(
      id: requiredBoundedString(json, 'id', maxLength: 128),
      deviceName: requiredBoundedString(json, 'device_name', maxLength: 100),
      deviceType: requiredBoundedString(json, 'device_type', maxLength: 20),
      createdAt: requiredDateTime(json, 'created_at'),
      lastActive: requiredDateTime(json, 'last_active'),
      isCurrent: isCurrent,
      serverTrusted: serverTrusted,
    );
  }

  final String id;
  final String deviceName;
  final String deviceType;
  final DateTime createdAt;
  final DateTime lastActive;
  final bool isCurrent;
  final bool serverTrusted;
}
