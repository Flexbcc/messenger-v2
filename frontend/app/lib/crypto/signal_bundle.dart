import 'dart:convert';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Converts between the `identity_key_bundle` JSON shape published to Home
/// Node (see shared/README.md) and libsignal_protocol_dart's PreKeyBundle.
/// This JSON shape IS the "identity_key_bundle" opaque blob from
/// spec/0300_CRYPTO.md's PreKey infrastructure — opaque to the server,
/// meaningful only to Crypto Providers on the client.
class SignalBundle {
  static Map<String, dynamic> toPublishableJson({
    required IdentityKeyPair identityKeyPair,
    required int registrationId,
    required SignedPreKeyRecord signedPreKey,
    required List<PreKeyRecord> preKeys,
  }) {
    return {
      'identity_key': base64Encode(identityKeyPair.getPublicKey().serialize()),
      'registration_id': registrationId,
      'signed_prekey': {
        'id': signedPreKey.id,
        'public_key': base64Encode(signedPreKey.getKeyPair().publicKey.serialize()),
        'signature': base64Encode(signedPreKey.signature),
      },
      'prekeys': preKeys
          .map((p) => {
                'id': p.id,
                'public_key': base64Encode(p.getKeyPair().publicKey.serialize()),
              })
          .toList(),
    };
  }

  /// Builds a PreKeyBundle from a peer's published JSON so we can start a
  /// session with them (X3DH). Consumes (conceptually) one one-time prekey —
  /// the caller is responsible for asking Home Node for a fresh one each time.
  static PreKeyBundle fromJson(Map<String, dynamic> json) {
    final identityKey = IdentityKey.fromBytes(
      base64Decode(json['identity_key'] as String),
      0,
    );
    final signed = json['signed_prekey'] as Map<String, dynamic>;
    final signedPreKeyPublic = Curve.decodePoint(
      base64Decode(signed['public_key'] as String),
      0,
    );

    int? preKeyId;
    dynamic preKeyPublic;
    final prekeys = json['prekeys'] as List<dynamic>? ?? [];
    if (prekeys.isNotEmpty) {
      final first = prekeys.first as Map<String, dynamic>;
      preKeyId = first['id'] as int;
      preKeyPublic = Curve.decodePoint(
        base64Decode(first['public_key'] as String),
        0,
      );
    }

    return PreKeyBundle(
      json['registration_id'] as int,
      1, // fixed logical deviceId — see MVP per-user simplification note
      preKeyId,
      preKeyPublic,
      signed['id'] as int,
      signedPreKeyPublic,
      base64Decode(signed['signature'] as String),
      identityKey,
    );
  }
}
