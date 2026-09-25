import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../security/crypto_encoding.dart';

class NodeOwnerPairingPayload {
  const NodeOwnerPairingPayload({
    required this.nodeId,
    required this.nodeRootPublicKey,
    required this.managementEndpoints,
    required this.managementCaFingerprint,
    required this.pairingId,
    required this.pairingSecret,
    required this.role,
    required this.expiresAt,
  });

  static const _maxCharacters = 8192;
  static const _maxTtl = Duration(minutes: 10);
  static const _allowedKeys = {
    'kind',
    'version',
    'protocol_version',
    'node_id',
    'node_root_public_key',
    'management_endpoints',
    'management_ca_fingerprint',
    'pairing_id',
    'pairing_secret',
    'role',
    'expires_at',
  };

  final String nodeId;
  final String nodeRootPublicKey;
  final List<Uri> managementEndpoints;
  final String managementCaFingerprint;
  final String pairingId;
  final String pairingSecret;
  final String role;
  final DateTime expiresAt;

  static NodeOwnerPairingPayload parse(String raw, {DateTime? now}) {
    if (raw.isEmpty || raw.length > _maxCharacters) {
      throw const FormatException('QR управления имеет недопустимый размер');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> ||
        decoded['kind'] != 'ouo_node_owner_pair' ||
        decoded['version'] != 1 ||
        decoded['protocol_version'] != 'ouo-owner-pair/1') {
      throw const FormatException('Это не QR управления OUO-нодой');
    }
    if (decoded.keys.any((key) => !_allowedKeys.contains(key))) {
      throw const FormatException('QR управления содержит лишние поля');
    }
    final rootKey = decoded['node_root_public_key']?.toString() ?? '';
    final rootBytes = decodeBase64Exact(
      rootKey,
      expectedBytes: 32,
      field: 'node_root_public_key',
      urlSafe: true,
    );
    final nodeId = decoded['node_id']?.toString() ?? '';
    if (nodeId != nodeIdFromRootPublicKey(rootBytes)) {
      throw const FormatException('NodeID не соответствует корневому ключу');
    }
    final endpointValues = decoded['management_endpoints'];
    if (endpointValues is! List ||
        endpointValues.isEmpty ||
        endpointValues.length > 5) {
      throw const FormatException('QR не содержит management endpoint');
    }
    final endpoints = endpointValues
        .map((value) {
          final uri = Uri.tryParse(value.toString());
          if (uri == null || !uri.hasAuthority || uri.path != '') {
            throw const FormatException('Некорректный management endpoint');
          }
          final loopback =
              uri.host == '127.0.0.1' ||
              uri.host == 'localhost' ||
              uri.host == '::1';
          if (uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) {
            throw const FormatException(
              'Management endpoint должен использовать HTTPS',
            );
          }
          return uri;
        })
        .toList(growable: false);
    final expiresAt = DateTime.tryParse(
      decoded['expires_at']?.toString() ?? '',
    )?.toUtc();
    final current = (now ?? DateTime.now()).toUtc();
    if (expiresAt == null || current.isAfter(expiresAt)) {
      throw const FormatException('QR управления истёк');
    }
    if (expiresAt.isAfter(current.add(_maxTtl))) {
      throw const FormatException('Срок действия QR управления слишком велик');
    }
    final pairingSecret = decoded['pairing_secret']?.toString() ?? '';
    if (pairingSecret.length < 32 || pairingSecret.length > 128) {
      throw const FormatException('Некорректный секрет сопряжения');
    }
    final role = decoded['role']?.toString() ?? '';
    if (!const {'viewer', 'operator', 'owner'}.contains(role)) {
      throw const FormatException('Неизвестная роль управления');
    }
    final pairingId = decoded['pairing_id']?.toString() ?? '';
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(pairingId)) {
      throw const FormatException('Некорректный идентификатор сопряжения');
    }
    return NodeOwnerPairingPayload(
      nodeId: nodeId,
      nodeRootPublicKey: rootKey,
      managementEndpoints: List.unmodifiable(endpoints),
      managementCaFingerprint:
          decoded['management_ca_fingerprint']?.toString() ?? '',
      pairingId: pairingId,
      pairingSecret: pairingSecret,
      role: role,
      expiresAt: expiresAt,
    );
  }

  static String nodeIdFromRootPublicKey(List<int> rootPublicKey) {
    final digest = sha256.convert(rootPublicKey).bytes;
    const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
    final output = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final byte in digest) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        output.write(alphabet[(buffer >> bits) & 31]);
      }
    }
    if (bits > 0) output.write(alphabet[(buffer << (5 - bits)) & 31]);
    return 'ouo-node-v1-$output';
  }
}
