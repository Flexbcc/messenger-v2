/// Client-reported metadata for a device session (local until server sync).
class DeviceSessionMeta {
  const DeviceSessionMeta({
    this.appVersion,
    this.osName,
    this.osVersion,
    this.connectionType,
    this.updatedAt,
  });

  final String? appVersion;
  final String? osName;
  final String? osVersion;
  final String? connectionType;
  final DateTime? updatedAt;

  String get platformLabel {
    if (osName == null || osName!.isEmpty) return '—';
    if (osVersion == null || osVersion!.isEmpty) return osName!;
    return '$osName $osVersion';
  }

  String encode() => [
        appVersion ?? '',
        osName ?? '',
        osVersion ?? '',
        connectionType ?? '',
        updatedAt?.toIso8601String() ?? '',
      ].join('|');

  static DeviceSessionMeta decode(String? raw) {
    if (raw == null || raw.isEmpty) return const DeviceSessionMeta();
    final p = raw.split('|');
    if (p.length < 5) return const DeviceSessionMeta();
    return DeviceSessionMeta(
      appVersion: p[0].isEmpty ? null : p[0],
      osName: p[1].isEmpty ? null : p[1],
      osVersion: p[2].isEmpty ? null : p[2],
      connectionType: p[3].isEmpty ? null : p[3],
      updatedAt: DateTime.tryParse(p[4]),
    );
  }
}
