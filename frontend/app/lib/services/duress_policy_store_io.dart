import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/duress_policy.dart';
import '../security/pin_security.dart';

/// PIN-encrypted duress policy — spec/0404 `duress_policy.v1`.
class DuressPolicyStore {
  DuressPolicyStore._();
  static final instance = DuressPolicyStore._();

  static const _fileName = 'duress_policy.v1';
  static final _aesGcm = AesGcm.with256bits();

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<DuressPolicyData?> load(String pin) async {
    final salt = await PinSecurity.realPinSalt();
    if (salt == null) return null;

    final file = await _file();
    if (!await file.exists()) return null;

    try {
      final raw = base64Decode(await file.readAsString());
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
      final json = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      return DuressPolicyData.fromJson(json);
    } catch (e) {
      debugPrint('DuressPolicyStore.load failed: $e');
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
    final packed = base64Encode([
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
    final file = await _file();
    await file.writeAsString(packed);
  }

  Future<void> wipe() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }
}
