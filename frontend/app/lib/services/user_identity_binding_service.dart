import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../crypto/auth_keypair.dart';
import '../security/network_identity.dart';

/// Creates the dual-signed bridge from the server's legacy account id to the
/// stable Identity Root held only by the endpoint.
class UserIdentityBindingService {
  const UserIdentityBindingService();

  static const _domain = 'OUO/USER_IDENTITY_BINDING/v1\u0000';

  Future<Map<String, dynamic>> issue({
    required String networkId,
    required String userId,
    required String deviceId,
    required AuthKeyPair deviceKey,
    DateTime? now,
  }) async {
    final identity = await NetworkIdentity.loadOrCreateUserKey(networkId);
    final binding = <String, dynamic>{
      'protocol_version': 'ouo-user-identity-binding/1',
      'object_version': 1,
      'binding_id': const Uuid().v4(),
      'user_id': userId,
      'identity_public_key': identity.publicKey,
      'identity_version': 1,
      'authorizing_device_id': deviceId,
      'authorizing_device_public_key': deviceKey.publicKeyBase64,
      'issued_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
    };
    final bytes = utf8.encode('$_domain${_canonicalJson(binding)}');
    binding['identity_signature'] = await identity.sign(bytes);
    binding['device_signature'] = await deviceKey.signBase64(bytes);
    return Map.unmodifiable(binding);
  }

  static String _canonicalJson(Map<String, dynamic> value) {
    final sorted = <String, dynamic>{};
    for (final key in value.keys.toList()..sort()) {
      sorted[key] = value[key];
    }
    return jsonEncode(sorted);
  }
}
