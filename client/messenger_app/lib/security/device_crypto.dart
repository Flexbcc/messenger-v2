import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'secure_prefs.dart';

/// Device-bound AES key — ciphertext in local SQLite is unreadable outside the app.
class DeviceCrypto {
  DeviceCrypto._();
  static final instance = DeviceCrypto._();

  static const _keyName = 'device_message_cache_key_v1';
  static final _aesGcm = AesGcm.with256bits();
  static final _random = Random.secure();

  Future<SecretKey> _secretKey() async {
    var raw = await SecurePrefs.instance.read(_keyName);
    if (raw == null) {
      final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
      raw = base64Encode(bytes);
      await SecurePrefs.instance.write(_keyName, raw);
    }
    return SecretKey(base64Decode(raw));
  }

  Future<String> encryptJson(Map<String, dynamic> json) async {
    final key = await _secretKey();
    final box = await _aesGcm.encrypt(utf8.encode(jsonEncode(json)), secretKey: key);
    return base64Encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  Future<Map<String, dynamic>?> decryptJson(String packed) async {
    try {
      final raw = base64Decode(packed);
      const nonceLen = 12;
      const macLen = 16;
      if (raw.length <= nonceLen + macLen) return null;
      final nonce = raw.sublist(0, nonceLen);
      final mac = Mac(raw.sublist(raw.length - macLen));
      final cipher = raw.sublist(nonceLen, raw.length - macLen);
      final clear = await _aesGcm.decrypt(
        SecretBox(cipher, nonce: nonce, mac: mac),
        secretKey: await _secretKey(),
      );
      return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('DeviceCrypto.decryptJson failed: $e');
      return null;
    }
  }
}
