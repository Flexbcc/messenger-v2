import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../services/account_scope_id.dart';
import '../services/security_meta_store.dart';
import 'secure_prefs.dart';

/// Shared Argon2id PIN hashing used by Private Mode and App Lock.
/// Hashes and salts live in OS secure storage (Keychain / Keystore),
/// namespaced by [setActiveUser] so accounts do not share PINs.
class PinSecurity {
  PinSecurity._();

  static const _realPinHashBase = 'private_mode_real_pin_hash';
  static const _realPinSaltBase = 'private_mode_real_pin_salt';
  static const _fakePinHashBase = 'private_mode_fake_pin_hash';
  static const _fakePinSaltBase = 'private_mode_fake_pin_salt';

  static String? _activeUserId;

  static void setActiveUser(String? userId) {
    _activeUserId = AccountScopeId.validateNullable(userId);
  }

  static String get realPinHashKey => _scoped(_realPinHashBase);
  static String get realPinSaltKey => _scoped(_realPinSaltBase);
  static String get fakePinHashKey => _scoped(_fakePinHashBase);
  static String get fakePinSaltKey => _scoped(_fakePinSaltBase);

  static String _scoped(String base) {
    final uid = AccountScopeId.require(_activeUserId);
    return '${base}_u_$uid';
  }

  static final _argon2 = Argon2id(
    parallelism: 1,
    memory: 19456,
    iterations: 2,
    hashLength: 32,
  );
  static final _secure = SecurePrefs.instance;
  static final _secureRandom = Random.secure();

  static List<int> newSalt() =>
      List<int>.generate(16, (_) => _secureRandom.nextInt(256));

  static Future<List<int>> deriveKeyBytes(String pin, List<int> salt) async {
    final key = await _argon2.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: salt,
    );
    return key.extractBytes();
  }

  static Future<String> hashToBase64(String pin, List<int> salt) async {
    return base64Encode(await deriveKeyBytes(pin, salt));
  }

  static Future<bool> verifyRealPin(String pin) async {
    final hash = await _secure.read(realPinHashKey);
    final saltB64 = await _secure.read(realPinSaltKey);
    if (hash == null || saltB64 == null) return false;
    return verifyHash(pin, saltB64, hash);
  }

  static Future<bool> verifyFakePin(String pin) async {
    final hash = await _secure.read(fakePinHashKey);
    final saltB64 = await _secure.read(fakePinSaltKey);
    if (hash == null || saltB64 == null) return false;
    return verifyHash(pin, saltB64, hash);
  }

  static Future<PinUnlockResult> evaluatePin(String pin) async {
    final realHash = await _secure.read(realPinHashKey);
    final realSaltB64 = await _secure.read(realPinSaltKey);
    if (realHash != null && realSaltB64 != null) {
      if (await verifyHash(pin, realSaltB64, realHash)) {
        return PinUnlockResult.realPin;
      }
    }
    final fakeHash = await _secure.read(fakePinHashKey);
    final fakeSaltB64 = await _secure.read(fakePinSaltKey);
    if (fakeHash != null && fakeSaltB64 != null) {
      if (await verifyHash(pin, fakeSaltB64, fakeHash)) {
        return PinUnlockResult.fakePin;
      }
    }
    return PinUnlockResult.invalid;
  }

  static Future<bool> isRealPinConfigured() =>
      _isCredentialPairConfigured(realPinHashKey, realPinSaltKey);

  static Future<bool> hasRealPin() => isRealPinConfigured();

  static Future<bool> hasFakePin() =>
      _isCredentialPairConfigured(fakePinHashKey, fakePinSaltKey);

  static Future<bool> _isCredentialPairConfigured(
    String hashKey,
    String saltKey,
  ) async {
    final hash = await _secure.read(hashKey);
    final salt = await _secure.read(saltKey);
    if (hash == null || salt == null) return false;
    try {
      return base64Decode(hash).length == 32 && base64Decode(salt).length >= 16;
    } on FormatException {
      return false;
    }
  }

  static Future<List<int>?> realPinSalt() async {
    final saltB64 = await _secure.read(realPinSaltKey);
    if (saltB64 == null) return null;
    try {
      final salt = base64Decode(saltB64);
      return salt.length == 16 ? salt : null;
    } on FormatException {
      return null;
    }
  }

  static Future<void> saveRealPin(String pin) async {
    _validatePin(pin);
    if (await verifyFakePin(pin)) {
      throw const FormatException(
        'Основной и дополнительный PIN должны отличаться',
      );
    }
    final salt = newSalt();
    final hash = await hashToBase64(pin, salt);
    await _secure.replacePair(
      firstKey: realPinSaltKey,
      firstValue: base64Encode(salt),
      secondKey: realPinHashKey,
      secondValue: hash,
    );
    await SecurityMetaStore.instance.recordPinChange();
  }

  static Future<void> saveFakePin(String pin) async {
    _validatePin(pin);
    if (await verifyRealPin(pin)) {
      throw const FormatException(
        'Основной и дополнительный PIN должны отличаться',
      );
    }
    final salt = newSalt();
    final hash = await hashToBase64(pin, salt);
    await _secure.replacePair(
      firstKey: fakePinSaltKey,
      firstValue: base64Encode(salt),
      secondKey: fakePinHashKey,
      secondValue: hash,
    );
    await SecurityMetaStore.instance.recordPinChange();
  }

  /// Clear PIN for the active user. Fails closed without an account scope.
  static Future<void> clearAll() async {
    await _secure.clearKeys([
      realPinHashKey,
      realPinSaltKey,
      fakePinHashKey,
      fakePinSaltKey,
    ]);
  }

  /// Clear legacy unscoped PIN keys left from before account scoping.
  static Future<void> clearUnscopedKeys() async {
    await _secure.clearKeys([
      _realPinHashBase,
      _realPinSaltBase,
      _fakePinHashBase,
      _fakePinSaltBase,
    ]);
  }

  static Future<bool> verifyHash(
    String pin,
    String saltB64,
    String expectedHashB64,
  ) async {
    if (pin.isEmpty || pin.length > 128) return false;
    try {
      final salt = base64Decode(saltB64);
      final expected = base64Decode(expectedHashB64);
      if (salt.length != 16 || expected.length != 32) return false;
      final candidate = await deriveKeyBytes(pin, salt);
      return _constantTimeEquals(candidate, expected);
    } on FormatException {
      return false;
    }
  }

  static void _validatePin(String pin) {
    if (pin.length < 4 ||
        pin.length > 128 ||
        pin.codeUnits.any((unit) => unit < 32 || unit == 127)) {
      throw const FormatException('PIN должен содержать от 4 до 128 символов');
    }
  }

  static bool _constantTimeEquals(List<int> left, List<int> right) {
    var difference = left.length ^ right.length;
    final length = left.length > right.length ? left.length : right.length;
    for (var index = 0; index < length; index++) {
      final leftByte = index < left.length ? left[index] : 0;
      final rightByte = index < right.length ? right[index] : 0;
      difference |= leftByte ^ rightByte;
    }
    return difference == 0;
  }
}

enum PinUnlockResult { realPin, fakePin, invalid }
