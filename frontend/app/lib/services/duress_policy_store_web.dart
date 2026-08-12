import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/duress_policy.dart';
import '../security/pin_security.dart';

class DuressPolicyFileStorage {
  DuressPolicyFileStorage._();
  static final instance = DuressPolicyFileStorage._();
  static const _key = 'duress_policy.v1';

  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  Future<void> write(String content) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, content);
  }

  Future<void> delete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

class DuressPolicyStore {
  DuressPolicyStore._();
  static final instance = DuressPolicyStore._();

  static final _aesGcm = AesGcm.with256bits();
  final _storage = DuressPolicyFileStorage.instance;

  Future<DuressPolicyData?> load(String pin) async {
    final salt = await PinSecurity.realPinSalt();
    if (salt == null) return null;
    final packed = await _storage.read();
    if (packed == null) return null;
    try {
      final raw = base64Decode(packed);
      const nonceLen = 12;
      const macLen = 16;
      if (raw.length <= nonceLen + macLen) return null;
      final nonce = raw.sublist(0, nonceLen);
      final mac = Mac(raw.sublist(raw.length - macLen));
      final cipher = raw.sublist(nonceLen, raw.length - macLen);
      final keyBytes = await PinSecurity.deriveKeyBytes(pin, salt);
      final clear = await _aesGcm.decrypt(
        SecretBox(cipher, nonce: nonce, mac: mac),
        secretKey: SecretKey(keyBytes),
      );
      return DuressPolicyData.fromJson(
        jsonDecode(utf8.decode(clear)) as Map<String, dynamic>,
      );
    } catch (e) {
      debugPrint('DuressPolicyStore.load web failed: $e');
      return null;
    }
  }

  Future<void> save(String pin, DuressPolicyData data) async {
    final salt = await PinSecurity.realPinSalt();
    if (salt == null) return;
    final keyBytes = await PinSecurity.deriveKeyBytes(pin, salt);
    final box = await _aesGcm.encrypt(
      utf8.encode(jsonEncode(data.toJson())),
      secretKey: SecretKey(keyBytes),
    );
    await _storage.write(
      base64Encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]),
    );
  }

  Future<void> wipe() async => _storage.delete();
}
