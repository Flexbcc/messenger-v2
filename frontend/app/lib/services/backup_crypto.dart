import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// AES-GCM blob encryption for catalog backups (uses project `cryptography`).
class BackupCrypto {
  BackupCrypto._();

  static final _aes = AesGcm.with256bits();

  static Future<Map<String, dynamic>> encryptJson(
    Map<String, dynamic> blob,
    String password,
  ) async {
    final plain = utf8.encode(const JsonEncoder().convert(blob));
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final secretKey = await _deriveKey(password, salt);
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(plain, secretKey: secretKey, nonce: nonce);
    return {
      'kind': 'encrypted_settings_backup',
      'alg': 'aes-gcm-256',
      'salt': base64Encode(salt),
      'nonce': base64Encode(box.nonce),
      'mac': base64Encode(box.mac.bytes),
      'ciphertext': base64Encode(box.cipherText),
    };
  }

  static Future<Map<String, dynamic>> decryptJson(
    Map<String, dynamic> envelope,
    String password,
  ) async {
    final salt = base64Decode(envelope['salt'] as String);
    final nonce = base64Decode(envelope['nonce'] as String);
    final mac = Mac(base64Decode(envelope['mac'] as String));
    final cipher = base64Decode(envelope['ciphertext'] as String);
    final secretKey = await _deriveKey(password, salt);
    final plain = await _aes.decrypt(
      SecretBox(cipher, nonce: nonce, mac: mac),
      secretKey: secretKey,
    );
    return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  }

  static Future<SecretKey> _deriveKey(String password, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    );
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  static Uint8List encodeEnvelope(Map<String, dynamic> envelope) =>
      Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(envelope)),
      );
}
