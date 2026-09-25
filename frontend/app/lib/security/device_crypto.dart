import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../services/debug_log.dart';
import 'crypto_encoding.dart';
import 'secure_prefs.dart';

/// Device-bound AES key — ciphertext in local SQLite is unreadable outside the app.
class DeviceCrypto {
  DeviceCrypto._();
  static final instance = DeviceCrypto._();

  static const _keyName = 'device_message_cache_key_v1';
  static const _maxClearBytes = 16 * 1024 * 1024;
  static const _maxPackedCharacters = 23 * 1024 * 1024;
  static final _aesGcm = AesGcm.with256bits();
  static final _random = Random.secure();

  SecretKey? _cached;

  Future<List<String>> _candidateRaws() async {
    final current = await SecurePrefs.instance.read(_keyName);
    if (current == null) return const [];
    decodeBase64Exact(
      current,
      expectedBytes: 32,
      field: 'DeviceCrypto key',
      maxEncodedCharacters: 64,
    );
    return [current];
  }

  Future<SecretKey> _secretKey() async {
    if (_cached != null) return _cached!;
    final candidates = await _candidateRaws();
    if (candidates.isNotEmpty) {
      await _adoptKey(candidates.first);
      return _cached!;
    }
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final raw = base64Encode(bytes);
    await SecurePrefs.instance.write(_keyName, raw);
    _cached = SecretKey(bytes);
    return _cached!;
  }

  Future<void> _adoptKey(String raw) async {
    final bytes = decodeBase64Exact(
      raw,
      expectedBytes: 32,
      field: 'DeviceCrypto key',
      maxEncodedCharacters: 64,
    );
    _cached = SecretKey(bytes);
    await SecurePrefs.instance.write(_keyName, raw);
  }

  Future<String> encryptJson(Map<String, dynamic> json) async {
    final clear = utf8.encode(jsonEncode(json));
    if (clear.isEmpty || clear.length > _maxClearBytes) {
      throw const FormatException('encrypted local payload exceeds size limit');
    }
    final key = await _secretKey();
    final box = await _aesGcm.encrypt(clear, secretKey: key);
    return base64Encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  Future<Map<String, dynamic>?> decryptJson(String packed) async {
    const nonceLen = 12;
    const macLen = 16;
    if (packed.isEmpty || packed.length > _maxPackedCharacters) return null;
    late final List<int> rawBytes;
    try {
      rawBytes = base64Decode(packed);
    } catch (error) {
      DebugLog.instance.warn(
        'crypto',
        'invalid encrypted local payload',
        error,
      );
      return null;
    }
    if (rawBytes.length <= nonceLen + macLen ||
        rawBytes.length > _maxClearBytes + nonceLen + macLen) {
      return null;
    }
    final nonce = rawBytes.sublist(0, nonceLen);
    final mac = Mac(rawBytes.sublist(rawBytes.length - macLen));
    final cipher = rawBytes.sublist(nonceLen, rawBytes.length - macLen);

    final candidates = await _candidateRaws();
    for (final raw in candidates) {
      try {
        final clear = await _aesGcm.decrypt(
          SecretBox(cipher, nonce: nonce, mac: mac),
          secretKey: SecretKey(base64Decode(raw)),
        );
        if (clear.length > _maxClearBytes) return null;
        final decoded = jsonDecode(utf8.decode(clear));
        if (decoded is! Map<String, dynamic>) return null;
        await _adoptKey(raw);
        return decoded;
      } catch (_) {}
    }

    DebugLog.instance.warn(
      'crypto',
      'encrypted local payload did not match the device key',
    );
    return null;
  }

  /// Drop in-memory key so next read re-probes secure storage after recovery.
  void invalidateCache() {
    _cached = null;
  }

  /// Permanently removes the key that encrypts the local message cache.
  Future<void> wipeLocalKey() async {
    await SecurePrefs.instance.remove(_keyName);
    invalidateCache();
  }

  Future<String> exportKey() async {
    final candidates = await _candidateRaws();
    if (candidates.isEmpty) {
      await _secretKey();
      return (await _candidateRaws()).first;
    }
    return candidates.first;
  }

  Future<void> importKey(String encodedKey) async {
    validateEncodedKey(encodedKey);
    await _adoptKey(encodedKey);
  }

  static void validateEncodedKey(String encodedKey) {
    decodeBase64Exact(
      encodedKey,
      expectedBytes: 32,
      field: 'local storage key',
      maxEncodedCharacters: 64,
    );
  }
}
