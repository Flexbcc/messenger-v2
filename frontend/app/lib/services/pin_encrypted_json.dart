import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../security/pin_security.dart';

/// Version-1 PIN-derived AES-GCM envelope shared by protected local stores.
class PinEncryptedJson {
  PinEncryptedJson._();

  static const maxClearBytes = 1024 * 1024;
  static const maxPackedCharacters = 1500000;
  static const _nonceLength = 12;
  static const _macLength = 16;
  static final _aesGcm = AesGcm.with256bits();

  static Future<Map<String, dynamic>?> decryptMap({
    required String packed,
    required String pin,
    required List<int> salt,
  }) async {
    if (packed.isEmpty || packed.length > maxPackedCharacters) return null;
    try {
      final raw = base64Decode(packed);
      if (raw.length <= _nonceLength + _macLength ||
          raw.length > maxClearBytes + _nonceLength + _macLength) {
        return null;
      }
      final nonce = raw.sublist(0, _nonceLength);
      final mac = Mac(raw.sublist(raw.length - _macLength));
      final cipher = raw.sublist(_nonceLength, raw.length - _macLength);
      final keyBytes = await PinSecurity.deriveKeyBytes(pin, salt);
      final clear = await _aesGcm.decrypt(
        SecretBox(cipher, nonce: nonce, mac: mac),
        secretKey: SecretKey(keyBytes),
      );
      if (clear.length > maxClearBytes) return null;
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is! Map<String, dynamic>) return null;
      return decoded;
    } on FormatException {
      return null;
    } on SecretBoxAuthenticationError {
      return null;
    }
  }

  static Future<String> encryptMap({
    required Map<String, dynamic> value,
    required String pin,
    required List<int> salt,
  }) async {
    final clear = utf8.encode(jsonEncode(value));
    if (clear.isEmpty || clear.length > maxClearBytes) {
      throw const FormatException('protected data exceeds size limit');
    }
    final keyBytes = await PinSecurity.deriveKeyBytes(pin, salt);
    final box = await _aesGcm.encrypt(clear, secretKey: SecretKey(keyBytes));
    return base64Encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }
}
