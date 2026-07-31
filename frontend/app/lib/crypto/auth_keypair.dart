import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_prefsKey);

    if (existing != null) {
      final seed = base64Decode(existing);
      final keyPair = await _algorithm.newKeyPairFromSeed(seed);
      final publicKey = await keyPair.extractPublicKey();
      return AuthKeyPair._(keyPair, publicKey.bytes);
    }

    final keyPair = await _algorithm.newKeyPair();
    final seed = await keyPair.extractPrivateKeyBytes();
    await prefs.setString(_prefsKey, base64Encode(seed));
    final publicKey = await keyPair.extractPublicKey();
    return AuthKeyPair._(keyPair, publicKey.bytes);
  }

  String get publicKeyBase64 => base64Encode(_publicKeyBytes);

  static Future<bool> existsLocally() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefsKey)?.isNotEmpty == true;
  }

  static Future<String?> exportSeed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefsKey);
  }

  static Future<void> importSeed(String encodedSeed) async {
    final seed = base64Decode(encodedSeed);
    if (seed.length != 32)
      throw const FormatException('Некорректный Ed25519 ключ');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, encodedSeed);
  }

  Future<String> signBase64(List<int> message) async {
    final signature = await _algorithm.sign(message, keyPair: _keyPair);
    return base64Encode(signature.bytes);
  }

  static Future<void> wipeLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}
