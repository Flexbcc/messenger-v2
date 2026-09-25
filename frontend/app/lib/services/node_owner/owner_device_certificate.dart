import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../../security/crypto_encoding.dart';
import 'node_owner_pairing_payload.dart';

class OwnerDeviceCertificate {
  OwnerDeviceCertificate._(this.json);

  static const _domain = 'OUO/OWNER_DEVICE_CERT/v1\u0000';
  static const _fields = {
    'protocol_version',
    'object_version',
    'node_id',
    'node_root_public_key',
    'device_id',
    'device_public_key',
    'role',
    'serial',
    'issued_at',
    'valid_until',
    'signature_algorithm',
    'signature',
  };

  final Map<String, dynamic> json;

  String get nodeId => json['node_id'].toString();
  String get serial => json['serial'].toString();

  static Future<OwnerDeviceCertificate> parseAndVerify(
    Map<String, dynamic> value, {
    required String expectedNodeId,
    required String expectedRootPublicKey,
    required String expectedDevicePublicKey,
    DateTime? now,
  }) async {
    if (value.keys.toSet().difference(_fields).isNotEmpty ||
        _fields.difference(value.keys.toSet()).isNotEmpty) {
      throw const FormatException('Некорректные поля owner-сертификата');
    }
    if (value['protocol_version'] != 'ouo-owner-device/1' ||
        value['object_version'] != 1 ||
        value['signature_algorithm'] != 'Ed25519') {
      throw const FormatException('Неподдерживаемый owner-сертификат');
    }
    final rootKey = value['node_root_public_key']?.toString() ?? '';
    final rootBytes = decodeBase64Exact(
      rootKey,
      expectedBytes: 32,
      field: 'node_root_public_key',
      urlSafe: true,
    );
    if (rootKey != expectedRootPublicKey ||
        value['node_id'] != expectedNodeId ||
        NodeOwnerPairingPayload.nodeIdFromRootPublicKey(rootBytes) !=
            expectedNodeId) {
      throw const FormatException('Сертификат выдан другой нодой');
    }
    if (value['device_public_key'] != expectedDevicePublicKey) {
      throw const FormatException('Сертификат выдан другому устройству');
    }
    if (!const {'viewer', 'operator', 'owner'}.contains(value['role'])) {
      throw const FormatException('Некорректная роль owner-сертификата');
    }
    final issuedAt = DateTime.tryParse(
      value['issued_at']?.toString() ?? '',
    )?.toUtc();
    final validUntil = DateTime.tryParse(
      value['valid_until']?.toString() ?? '',
    )?.toUtc();
    final current = (now ?? DateTime.now()).toUtc();
    if (issuedAt == null ||
        validUntil == null ||
        !validUntil.isAfter(issuedAt)) {
      throw const FormatException('Некорректный срок owner-сертификата');
    }
    if (current.isBefore(issuedAt) || current.isAfter(validUntil)) {
      throw const FormatException('Owner-сертификат сейчас недействителен');
    }
    final unsigned = Map<String, dynamic>.from(value)..remove('signature');
    final payload = utf8.encode('$_domain${_canonicalJson(unsigned)}');
    final signatureBytes = decodeBase64Exact(
      value['signature']?.toString() ?? '',
      expectedBytes: 64,
      field: 'owner certificate signature',
      urlSafe: true,
    );
    final valid = await Ed25519().verify(
      payload,
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(rootBytes, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) {
      throw const FormatException('Подпись owner-сертификата недействительна');
    }
    return OwnerDeviceCertificate._(Map.unmodifiable(Map.from(value)));
  }

  static String _canonicalJson(Map<String, dynamic> value) {
    final sorted = <String, dynamic>{};
    for (final key in value.keys.toList()..sort()) {
      sorted[key] = value[key];
    }
    return jsonEncode(sorted);
  }
}
