import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../security/secure_prefs.dart';

/// Device auth keypair — standard Ed25519, deliberately separate from the
/// Signal identity key in crypto_service.dart (Single Responsibility, see
/// shared/README.md). Used only to prove "this is the same device" to the
/// Home Node via challenge-response (spec/0300_CRYPTO.md — no passwords).
///
/// The Ed25519 seed (private key material) is stored in flutter_secure_storage
/// (OS keychain). Migration from plain SharedPreferences is automatic.
class AuthKeyPair {
  AuthKeyPair._(this._keyPair, this._publicKeyBytes);

  // Secure storage key (OS keychain)
  static const _secureKey = 'auth_keypair_seed_b64_secure';
  // Legacy SharedPreferences key (for migration)
  static const _legacyPrefsKey = 'auth_keypair_seed_b64';

  final SimpleKeyPair _keyPair;
  final List<int> _publicKeyBytes;

  static final _algorithm = Ed25519();

  static Future<AuthKeyPair> loadOrCreate() async {
    final secure = SecurePrefs.instance;
    String? seedB64 = await secure.read(_secureKey);

    // Migration: move seed from plain SharedPreferences to secure storage
    if (seedB64 == null) {
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(_legacyPrefsKey);
      if (legacy != null) {
        seedB64 = legacy;
        await secure.write(_secureKey, seedB64);
        await prefs.remove(_legacyPrefsKey);
      }
    }

    if (seedB64 != null) {
      final seed = base64Decode(seedB64);
      final keyPair = await _algorithm.newKeyPairFromSeed(seed);
      final publicKey = await keyPair.extractPublicKey();
      return AuthKeyPair._(keyPair, publicKey.bytes);
    }

    // Generate new keypair
    final keyPair = await _algorithm.newKeyPair();
    final seed = await keyPair.extractPrivateKeyBytes();
    await secure.write(_secureKey, base64Encode(seed));
    final publicKey = await keyPair.extractPublicKey();
    return AuthKeyPair._(keyPair, publicKey.bytes);
  }

  String get publicKeyBase64 => base64Encode(_publicKeyBytes);

  Future<String> signBase64(List<int> message) async {
    final signature = await _algorithm.sign(message, keyPair: _keyPair);
    return base64Encode(signature.bytes);
  }

  static Future<void> wipeLocal() async {
    await SecurePrefs.instance.remove(_secureKey);
    // Also clean up any legacy plain-text key
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_legacyPrefsKey);
  }
}
