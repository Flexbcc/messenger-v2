import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_prefs.dart';

/// Device-bound AES key — ciphertext in local SQLite is unreadable outside the app.
class DeviceCrypto {
  DeviceCrypto._();
  static final instance = DeviceCrypto._();

  static const _keyName = 'device_message_cache_key_v1';
  static final _aesGcm = AesGcm.with256bits();
  static final _random = Random.secure();

  SecretKey? _cached;
  final _candidatesTried = <String>{};

  static const _legacyMacStorage = FlutterSecureStorage(
    mOptions: MacOsOptions(
      groupId: 'com.messenger.messengerApp',
      useDataProtectionKeyChain: false,
    ),
  );

  static const _plainMacStorage = FlutterSecureStorage(
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );

  Future<List<String>> _candidateRaws() async {
    final out = <String>[];
    void add(String? v) {
      if (v != null && v.isNotEmpty && !out.contains(v)) out.add(v);
    }

    add(await SecurePrefs.instance.read(_keyName));

    try {
      add(await _legacyMacStorage.read(key: _keyName));
    } catch (_) {}
    try {
      add(await _plainMacStorage.read(key: _keyName));
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    add(prefs.getString('secure_fallback::$_keyName'));

    return out;
  }

  Future<SecretKey> _secretKey() async {
    if (_cached != null) return _cached!;
    final candidates = await _candidateRaws();
    if (candidates.isNotEmpty) {
      _cached = SecretKey(base64Decode(candidates.first));
      return _cached!;
    }
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final raw = base64Encode(bytes);
    await SecurePrefs.instance.write(_keyName, raw);
    _cached = SecretKey(bytes);
    return _cached!;
  }

  Future<void> _adoptKey(String raw) async {
    _cached = SecretKey(base64Decode(raw));
    await SecurePrefs.instance.write(_keyName, raw);
  }

  Future<String> encryptJson(Map<String, dynamic> json) async {
    final key = await _secretKey();
    final box = await _aesGcm.encrypt(utf8.encode(jsonEncode(json)), secretKey: key);
    return base64Encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  Future<Map<String, dynamic>?> decryptJson(String packed) async {
    const nonceLen = 12;
    const macLen = 16;
    late final List<int> rawBytes;
    try {
      rawBytes = base64Decode(packed);
    } catch (e) {
      debugPrint('DeviceCrypto.decryptJson failed: $e');
      return null;
    }
    if (rawBytes.length <= nonceLen + macLen) return null;
    final nonce = rawBytes.sublist(0, nonceLen);
    final mac = Mac(rawBytes.sublist(rawBytes.length - macLen));
    final cipher = rawBytes.sublist(nonceLen, rawBytes.length - macLen);

    final candidates = await _candidateRaws();
    for (final raw in candidates) {
      if (_candidatesTried.contains('$raw:${packed.hashCode}')) continue;
      try {
        final clear = await _aesGcm.decrypt(
          SecretBox(cipher, nonce: nonce, mac: mac),
          secretKey: SecretKey(base64Decode(raw)),
        );
        await _adoptKey(raw);
        return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      } catch (_) {
        _candidatesTried.add('$raw:${packed.hashCode}');
      }
    }

    debugPrint('DeviceCrypto.decryptJson failed: SecretBoxAuthenticationError (no matching key)');
    return null;
  }

  /// Drop in-memory key so next read re-probes Keychain/prefs (after recovery).
  void invalidateCache() {
    _cached = null;
    _candidatesTried.clear();
  }
}
