import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../security/network_identity.dart';

class HomeMigrationTicketService {
  const HomeMigrationTicketService();

  static const _domain = 'OUO/HOME_MIGRATION/v1\u0000';

  Future<Map<String, dynamic>> issue({
    required String networkId,
    required String userId,
    required int identityVersion,
    required int routeEpoch,
    required String fromHome,
    required String toHome,
    required Map<String, dynamic> manifest,
    required String expectedManifestHash,
    DateTime? now,
  }) async {
    final actualHash = sha256
        .convert(utf8.encode(_canonicalValue(manifest)))
        .toString();
    if (actualHash != expectedManifestHash) {
      throw const FormatException('Home migration manifest hash mismatch');
    }
    final identity = await NetworkIdentity.loadOrCreateUserKey(networkId);
    final issuedAt = (now ?? DateTime.now()).toUtc();
    final random = Random.secure();
    final ticket = <String, dynamic>{
      'protocol_version': 'ouo-home-migration/1',
      'object_version': 1,
      'migration_id': const Uuid().v4(),
      'user_id': userId,
      'identity_public_key': identity.publicKey,
      'identity_version': identityVersion,
      'route_epoch': routeEpoch,
      'from_home': fromHome,
      'to_home': toHome,
      'device_manifest_hash': actualHash,
      'issued_at': issuedAt.toIso8601String(),
      'expires_at': issuedAt.add(const Duration(minutes: 10)).toIso8601String(),
      'nonce': base64Encode(List<int>.generate(32, (_) => random.nextInt(256))),
    };
    final payload = utf8.encode('$_domain${_canonicalValue(ticket)}');
    ticket['signature'] = await identity.sign(payload);
    return Map.unmodifiable(ticket);
  }

  static String _canonicalValue(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalValue(value[key])}').join(',')}}';
    }
    if (value is List) {
      return '[${value.map(_canonicalValue).join(',')}]';
    }
    return jsonEncode(value);
  }
}
