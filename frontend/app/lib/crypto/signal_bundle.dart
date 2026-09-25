import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../security/crypto_encoding.dart';

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
        'public_key': base64Encode(
          signedPreKey.getKeyPair().publicKey.serialize(),
        ),
        'signature': base64Encode(signedPreKey.signature),
      },
      'prekeys': preKeys
          .map(
            (p) => {
              'id': p.id,
              'public_key': base64Encode(p.getKeyPair().publicKey.serialize()),
            },
          )
          .toList(),
    };
  }

  /// Builds a PreKeyBundle from a peer's published JSON so we can start a
  /// session with them (X3DH). Consumes (conceptually) one one-time prekey —
  /// the caller is responsible for asking Home Node for a fresh one each time.
  static PreKeyBundle fromJson(Map<String, dynamic> json) {
    final registrationId = _boundedId(
      json['registration_id'],
      'registration_id',
      minimum: 1,
    );
    final identityKey = IdentityKey.fromBytes(
      decodeBase64Exact(
        json['identity_key'],
        expectedBytes: 33,
        field: 'identity_key',
        maxEncodedCharacters: 128,
      ),
      0,
    );
    final signedRaw = json['signed_prekey'];
    if (signedRaw is! Map<String, dynamic>) {
      throw const FormatException('signed_prekey must be an object');
    }
    final signed = signedRaw;
    final signedPreKeyId = _boundedId(signed['id'], 'signed_prekey.id');
    final signedPreKeyPublic = Curve.decodePoint(
      decodeBase64Exact(
        signed['public_key'],
        expectedBytes: 33,
        field: 'signed_prekey.public_key',
        maxEncodedCharacters: 128,
      ),
      0,
    );
    final signature = decodeBase64Exact(
      signed['signature'],
      expectedBytes: 64,
      field: 'signed_prekey.signature',
      maxEncodedCharacters: 128,
    );

    final prekeysRaw = json['prekeys'];
    if (prekeysRaw is! List || prekeysRaw.isEmpty || prekeysRaw.length > 256) {
      throw const FormatException('prekeys must contain 1 to 256 entries');
    }
    final ids = <int>{};
    final parsed = <({int id, Uint8List publicKey})>[];
    for (final raw in prekeysRaw) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('prekey must be an object');
      }
      final id = _boundedId(raw['id'], 'prekey.id');
      if (!ids.add(id)) throw const FormatException('duplicate prekey id');
      parsed.add((
        id: id,
        publicKey: decodeBase64Exact(
          raw['public_key'],
          expectedBytes: 33,
          field: 'prekey.public_key',
          maxEncodedCharacters: 128,
        ),
      ));
    }
    final first = parsed.first;
    final preKeyPublic = Curve.decodePoint(first.publicKey, 0);

    return PreKeyBundle(
      registrationId,
      1, // fixed logical deviceId — see MVP per-user simplification note
      first.id,
      preKeyPublic,
      signedPreKeyId,
      signedPreKeyPublic,
      signature,
      identityKey,
    );
  }

  static int _boundedId(Object? value, String field, {int minimum = 0}) {
    if (value is! int || value < minimum || value > 2147483647) {
      throw FormatException('$field is invalid');
    }
    return value;
  }
}
