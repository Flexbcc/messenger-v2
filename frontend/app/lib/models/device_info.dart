class DeviceInfo {
  DeviceInfo({
    required this.id,
    required this.deviceName,
    required this.deviceType,
    required this.createdAt,
    required this.lastActive,
    required this.isCurrent,
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
    id: json['id'] as String,
    deviceName: json['device_name'] as String,
    deviceType: json['device_type'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
    lastActive: DateTime.parse(json['last_active'] as String),
    isCurrent: json['is_current'] as bool,
  );

  final String id;
  final String deviceName;
  final String deviceType;
  final DateTime createdAt;
  final DateTime lastActive;
  final bool isCurrent;
}
