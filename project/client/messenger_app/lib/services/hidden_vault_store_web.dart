import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/hidden_chat.dart';
import '../security/pin_security.dart';

/// Web implementation — SharedPreferences instead of dart:io File.
class VaultFileStorage {
  VaultFileStorage._();
  static final instance = VaultFileStorage._();

  static const _key = 'hidden_vault.v1';

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

/// Same API surface as IO store — used via conditional export.
class HiddenVaultStore {
  HiddenVaultStore._();
  static final instance = HiddenVaultStore._();

  static final _aesGcm = AesGcm.with256bits();
  final _storage = VaultFileStorage.instance;

  Future<HiddenVaultData?> load(String pin) async {
    final salt = await PinSecurity.realPinSalt();
    if (salt == null) return HiddenVaultData();

    final stored = await _storage.read();
    if (stored == null || stored.isEmpty) return HiddenVaultData();

    try {
      final raw = base64Decode(stored);
      const nonceLen = 12;
      const macLen = 16;
      if (raw.length <= nonceLen + macLen) return null;
      final nonce = raw.sublist(0, nonceLen);
      final mac = Mac(raw.sublist(raw.length - macLen));
      final cipher = raw.sublist(nonceLen, raw.length - macLen);
      final keyBytes = await PinSecurity.deriveKeyBytes(pin, salt);
      final secretKey = SecretKey(keyBytes);
      final clear = await _aesGcm.decrypt(
        SecretBox(cipher, nonce: nonce, mac: mac),
        secretKey: secretKey,
      );
      final json = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      return HiddenVaultData.fromJson(json);
    } catch (e) {
      debugPrint('HiddenVaultStore.load failed: $e');
      return null;
    }
  }

  Future<void> save(String pin, HiddenVaultData data) async {
    final salt = await PinSecurity.realPinSalt();
    if (salt == null) return;

    final keyBytes = await PinSecurity.deriveKeyBytes(pin, salt);
    final secretKey = SecretKey(keyBytes);
    final box = await _aesGcm.encrypt(
      utf8.encode(jsonEncode(data.toJson())),
      secretKey: secretKey,
    );
    final out = base64Encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
    await _storage.write(out);
  }

  Future<void> wipe() async {
    await _storage.delete();
  }
}
