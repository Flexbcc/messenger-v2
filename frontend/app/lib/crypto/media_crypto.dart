import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Client-side attachment encryption per spec/0603_MEDIA_NODE.md: the file
/// key never leaves the E2EE envelope, Media Node only ever stores/serves
/// ciphertext it cannot decrypt.
class MediaCrypto {
  static final _aes = AesGcm.with256bits();

  /// Encrypts [bytes] with a fresh random key. Returns the ciphertext to
  /// upload plus a small pointer (to be Signal-encrypted as the message
  /// body) carrying the key so only conversation participants can decrypt.
  static Future<(Uint8List ciphertextForUpload, Map<String, dynamic> pointer)>
  encrypt(
    Uint8List bytes, {
    required String filename,
    required String mime,
  }) async {
    final secretKey = await _aes.newSecretKey();
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(bytes, secretKey: secretKey, nonce: nonce);
    final keyBytes = await secretKey.extractBytes();

    final combined = Uint8List.fromList([
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
    final pointer = {
      'key': base64Encode(keyBytes),
      'filename': filename,
      'mime': mime,
    };
    return (combined, pointer);
  }

  static Future<Uint8List> decrypt(
    Uint8List combined,
    Map<String, dynamic> pointer,
  ) async {
    final nonceLength = 12;
    final macLength = 16;
    final nonce = combined.sublist(0, nonceLength);
    final mac = combined.sublist(combined.length - macLength);
    final cipherText = combined.sublist(
      nonceLength,
      combined.length - macLength,
    );

    final keyBytes = base64Decode(pointer['key'] as String);
    final secretKey = SecretKey(keyBytes);
    final box = SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
    final plain = await _aes.decrypt(box, secretKey: secretKey);
    return Uint8List.fromList(plain);
  }
}
