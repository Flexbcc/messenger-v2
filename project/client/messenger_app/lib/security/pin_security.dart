import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../services/security_meta_store.dart';
import 'secure_prefs.dart';

/// Shared Argon2id PIN hashing used by Private Mode and App Lock.
/// Hashes and salts live in OS secure storage (Keychain / Keystore).
class PinSecurity {
  PinSecurity._();

  static const realPinHashKey = 'private_mode_real_pin_hash';
  static const realPinSaltKey = 'private_mode_real_pin_salt';
  static const fakePinHashKey = 'private_mode_fake_pin_hash';
  static const fakePinSaltKey = 'private_mode_fake_pin_salt';

  static final _argon2 = Argon2id(parallelism: 1, memory: 19456, iterations: 2, hashLength: 32);
  static final _secure = SecurePrefs.instance;
  static final _secureRandom = Random.secure();

  static List<int> newSalt() => List<int>.generate(16, (_) => _secureRandom.nextInt(256));

  static Future<List<int>> deriveKeyBytes(String pin, List<int> salt) async {
    final key = await _argon2.deriveKey(secretKey: SecretKey(utf8.encode(pin)), nonce: salt);
    return key.extractBytes();
  }

  static Future<String> hashToBase64(String pin, List<int> salt) async {
    return base64Encode(await deriveKeyBytes(pin, salt));
  }

  static Future<bool> verifyRealPin(String pin) async {
    final hash = await _secure.read(realPinHashKey);
    final saltB64 = await _secure.read(realPinSaltKey);
    if (hash == null || saltB64 == null) return false;
    final candidate = await hashToBase64(pin, base64Decode(saltB64));
    return candidate == hash;
  }

  static Future<PinUnlockResult> evaluatePin(String pin) async {
    final realHash = await _secure.read(realPinHashKey);
    final realSaltB64 = await _secure.read(realPinSaltKey);
    if (realHash != null && realSaltB64 != null) {
      final candidate = await hashToBase64(pin, base64Decode(realSaltB64));
      if (candidate == realHash) return PinUnlockResult.realPin;
    }
    final fakeHash = await _secure.read(fakePinHashKey);
    final fakeSaltB64 = await _secure.read(fakePinSaltKey);
    if (fakeHash != null && fakeSaltB64 != null) {
      final candidate = await hashToBase64(pin, base64Decode(fakeSaltB64));
      if (candidate == fakeHash) return PinUnlockResult.fakePin;
    }
    return PinUnlockResult.invalid;
  }

  static Future<bool> isRealPinConfigured() async => _secure.containsKey(realPinHashKey);

  static Future<bool> hasRealPin() => isRealPinConfigured();

  static Future<bool> hasFakePin() async => _secure.containsKey(fakePinHashKey);

  static Future<List<int>?> realPinSalt() async {
    final saltB64 = await _secure.read(realPinSaltKey);
    return saltB64 != null ? base64Decode(saltB64) : null;
  }

  static Future<void> saveRealPin(String pin) async {
    final salt = newSalt();
    final hash = await hashToBase64(pin, salt);
    await _secure.write(realPinHashKey, hash);
    await _secure.write(realPinSaltKey, base64Encode(salt));
    await SecurityMetaStore.instance.recordPinChange();
  }

  static Future<void> saveFakePin(String pin) async {
    final salt = newSalt();
    final hash = await hashToBase64(pin, salt);
    await _secure.write(fakePinHashKey, hash);
    await _secure.write(fakePinSaltKey, base64Encode(salt));
    await SecurityMetaStore.instance.recordPinChange();
  }

  static Future<void> clearAll() async {
    await _secure.clearKeys([realPinHashKey, realPinSaltKey, fakePinHashKey, fakePinSaltKey]);
  }
}

enum PinUnlockResult { realPin, fakePin, invalid }
