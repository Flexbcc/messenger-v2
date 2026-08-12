import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/hidden_chat.dart';
import '../security/pin_security.dart';

/// Encrypted at-rest storage for hidden chats (AES-GCM, key from PIN) — native/desktop.
class HiddenVaultStore {
  HiddenVaultStore._();
  static final instance = HiddenVaultStore._();

  static const _fileName = 'hidden_vault.v1';
  static final _aesGcm = AesGcm.with256bits();

  Future<File> _vaultFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<HiddenVaultData?> load(String pin) async {
    final salt = await PinSecurity.realPinSalt();
    if (salt == null) return HiddenVaultData();

    final file = await _vaultFile();
    if (!await file.exists()) return HiddenVaultData();

    try {
      final raw = base64Decode(await file.readAsString());
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
    final out = base64Encode([
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
    final file = await _vaultFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(out);
  }

  Future<void> wipe() async {
    final file = await _vaultFile();
    if (await file.exists()) await file.delete();
  }
}
