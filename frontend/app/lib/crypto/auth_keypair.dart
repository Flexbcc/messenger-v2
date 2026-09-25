import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../security/crypto_encoding.dart';
import '../security/secure_prefs.dart';

/// Device auth keypair — standard Ed25519, deliberately separate from the
/// Signal identity key in crypto_service.dart (Single Responsibility, see
/// shared/README.md). Used only to prove "this is the same device" to the
/// Home Node via challenge-response (spec/0300_CRYPTO.md — no passwords).
class AuthKeyPair {
  AuthKeyPair._(this._keyPair, this._publicKeyBytes);

  static const _prefsKey = 'auth_keypair_seed_b64';
  final SimpleKeyPair _keyPair;
  final List<int> _publicKeyBytes;

  static final _algorithm = Ed25519();

  static Future<AuthKeyPair> loadOrCreate() async {
    final existing = await SecurePrefs.instance.read(_prefsKey);

    if (existing != null) {
      final seed = _decodeSeed(existing);
      final keyPair = await _algorithm.newKeyPairFromSeed(seed);
      final publicKey = await keyPair.extractPublicKey();
      return AuthKeyPair._(keyPair, publicKey.bytes);
    }

    final keyPair = await _algorithm.newKeyPair();
    final seed = await keyPair.extractPrivateKeyBytes();
    await SecurePrefs.instance.write(_prefsKey, base64Encode(seed));
    final publicKey = await keyPair.extractPublicKey();
    return AuthKeyPair._(keyPair, publicKey.bytes);
  }

  String get publicKeyBase64 => base64Encode(_publicKeyBytes);

  static Future<bool> existsLocally() async {
    return SecurePrefs.instance.containsKey(_prefsKey);
  }

  static Future<String?> exportSeed() => SecurePrefs.instance.read(_prefsKey);

  static Future<void> importSeed(String encodedSeed) async {
    validateSeed(encodedSeed);
    await SecurePrefs.instance.write(_prefsKey, encodedSeed);
  }

  static void validateSeed(String encodedSeed) {
    _decodeSeed(encodedSeed);
  }

  static List<int> _decodeSeed(String encodedSeed) => decodeBase64Exact(
    encodedSeed,
    expectedBytes: 32,
    field: 'Ed25519 seed',
    maxEncodedCharacters: 64,
  );

  Future<String> signBase64(List<int> message) async {
    final signature = await _algorithm.sign(message, keyPair: _keyPair);
    return base64Encode(signature.bytes);
  }

  static Future<void> wipeLocal() async {
    await SecurePrefs.instance.remove(_prefsKey);
  }
}
