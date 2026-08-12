import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'secure_prefs.dart';

/// Stable cryptographic identity of a network, independent from node URLs.
class NetworkIdentity {
  NetworkIdentity._();

  static final _hash = Sha256();
  static final _signer = Ed25519();

  static Future<String> idFromTrustAnchor(String trustAnchorPublicKey) async {
    final normalized = trustAnchorPublicKey.trim();
    if (normalized.isEmpty) {
      throw const FormatException('Network trust anchor is empty');
    }
    final digest = await _hash.hash(utf8.encode(normalized));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  static String accountNamespace({
    required String networkId,
    required String userId,
  }) {
    if (networkId.trim().isEmpty || userId.trim().isEmpty) {
      throw const FormatException('Network and user identifiers are required');
    }
    return 'n_${_safe(networkId)}_u_${_safe(userId)}';
  }

  static String _safe(String value) =>
      base64UrlEncode(utf8.encode(value.trim())).replaceAll('=', '');

  static Future<NetworkUserKey> loadOrCreateUserKey(String networkId) async {
    if (networkId.trim().isEmpty) {
      throw const FormatException('Network identifier is required');
    }
    final storageKey = 'network_user_identity_${_safe(networkId)}';
    var seed = await SecurePrefs.instance.read(storageKey);
    if (seed == null) {
      final pair = await _signer.newKeyPair();
      seed = base64Encode(await pair.extractPrivateKeyBytes());
      await SecurePrefs.instance.write(storageKey, seed);
    }
    final pair = await _signer.newKeyPairFromSeed(base64Decode(seed));
    final publicKey = await pair.extractPublicKey();
    final fingerprint = await _hash.hash(publicKey.bytes);
    return NetworkUserKey(
      networkId: networkId,
      publicKey: base64Encode(publicKey.bytes),
      fingerprint: base64UrlEncode(fingerprint.bytes).replaceAll('=', ''),
      keyPair: pair,
    );
  }
}

class NetworkUserKey {
  const NetworkUserKey({
    required this.networkId,
    required this.publicKey,
    required this.fingerprint,
    required SimpleKeyPair keyPair,
  }) : _keyPair = keyPair;

  final String networkId;
  final String publicKey;
  final String fingerprint;
  final SimpleKeyPair _keyPair;

  Future<String> sign(List<int> bytes) async {
    final signature = await Ed25519().sign(bytes, keyPair: _keyPair);
    return base64Encode(signature.bytes);
  }
}
