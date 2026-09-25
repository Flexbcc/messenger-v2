class ManagedNode {
  const ManagedNode({
    required this.localLabel,
    required this.nodeId,
    required this.endpoints,
    required this.caFingerprint,
    required this.ownerDeviceCertificate,
    required this.keyAlias,
    this.lastVerifiedAt,
    this.lastStatus,
  });

  final String localLabel;
  final String nodeId;
  final List<String> endpoints;
  final String caFingerprint;
  final Map<String, dynamic> ownerDeviceCertificate;
  final String keyAlias;
  final DateTime? lastVerifiedAt;
  final String? lastStatus;

  String get certificateSerial =>
      ownerDeviceCertificate['serial']?.toString() ?? '';

  Map<String, dynamic> toJson() => {
    'local_label': localLabel,
    'node_id': nodeId,
    'endpoints': endpoints,
    'ca_fingerprint': caFingerprint,
    'owner_device_certificate': ownerDeviceCertificate,
    'key_alias': keyAlias,
    if (lastVerifiedAt != null)
      'last_verified_at': lastVerifiedAt!.toUtc().toIso8601String(),
    if (lastStatus != null) 'last_status': lastStatus,
  };

  factory ManagedNode.fromJson(Map<String, dynamic> json) {
    final endpointsRaw = json['endpoints'];
    final certificateRaw = json['owner_device_certificate'];
    if (endpointsRaw is! List || certificateRaw is! Map) {
      throw const FormatException('Некорректная запись управляемой ноды');
    }
    final endpoints = endpointsRaw.map((value) => value.toString()).toList();
    final certificate = Map<String, dynamic>.from(certificateRaw);
    final nodeId = json['node_id']?.toString() ?? '';
    if (nodeId.isEmpty || certificate['node_id']?.toString() != nodeId) {
      throw const FormatException('Сертификат принадлежит другой ноде');
    }
    if (endpoints.isEmpty || endpoints.any((value) => !_validEndpoint(value))) {
      throw const FormatException('Некорректный management endpoint');
    }
    final keyAlias = json['key_alias']?.toString() ?? '';
    final serial = certificate['serial']?.toString() ?? '';
    if (keyAlias.isEmpty || serial.isEmpty) {
      throw const FormatException('Неполная запись управляемой ноды');
    }
    return ManagedNode(
      localLabel: json['local_label']?.toString() ?? nodeId,
      nodeId: nodeId,
      endpoints: List.unmodifiable(endpoints),
      caFingerprint: json['ca_fingerprint']?.toString() ?? '',
      ownerDeviceCertificate: Map.unmodifiable(certificate),
      keyAlias: keyAlias,
      lastVerifiedAt: DateTime.tryParse(
        json['last_verified_at']?.toString() ?? '',
      )?.toUtc(),
      lastStatus: json['last_status']?.toString(),
    );
  }

  static bool _validEndpoint(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority || uri.path != '') return false;
    if (uri.scheme == 'https') return true;
    // Plain HTTP is restricted to loopback for local development/CLI bridges.
    return uri.scheme == 'http' &&
        (uri.host == '127.0.0.1' ||
            uri.host == 'localhost' ||
            uri.host == '::1');
  }
}
