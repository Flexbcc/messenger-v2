import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../models/attachment_pointer.dart';

/// Client-side attachment encryption per spec/0603_MEDIA_NODE.md: the file
/// key never leaves the E2EE envelope, Media Node only ever stores/serves
/// ciphertext it cannot decrypt.
class MediaCrypto {
  static final _aes = AesGcm.with256bits();
  static const _nonceLength = 12;
  static const _macLength = 16;
  static const _keyLength = 32;
  static const _maxPlaintextBytes = maxAttachmentPlaintextBytes;
  static const _maxCiphertextBytes = maxAttachmentCiphertextBytes;

  /// Encrypts [bytes] with a fresh random key. Returns the ciphertext to
  /// upload plus a small pointer (to be Signal-encrypted as the message
  /// body) carrying the key so only conversation participants can decrypt.
  static Future<(Uint8List ciphertextForUpload, Map<String, dynamic> pointer)>
  encrypt(
    Uint8List bytes, {
    required String filename,
    required String mime,
  }) async {
    if (bytes.isEmpty || bytes.length > _maxPlaintextBytes) {
      throw ArgumentError('attachment size is invalid');
    }
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
      'size': bytes.length,
    };
    return (combined, pointer);
  }

  static Future<Uint8List> decrypt(
    Uint8List combined,
    Map<String, dynamic> pointer,
  ) async {
    if (combined.length <= _nonceLength + _macLength ||
        combined.length > _maxCiphertextBytes) {
      throw const FormatException('encrypted attachment size is invalid');
    }
    final encodedKey = pointer['key'];
    if (encodedKey is! String || encodedKey.length != 44) {
      throw const FormatException('attachment key is invalid');
    }
    late final Uint8List keyBytes;
    try {
      keyBytes = base64Decode(encodedKey);
    } on FormatException {
      throw const FormatException('attachment key is invalid');
    }
    if (keyBytes.length != _keyLength || base64Encode(keyBytes) != encodedKey) {
      throw const FormatException('attachment key is invalid');
    }
    final declaredSize = pointer['size'];
    if (declaredSize != null &&
        (declaredSize is! int ||
            declaredSize <= 0 ||
            declaredSize > _maxPlaintextBytes)) {
      throw const FormatException('attachment plaintext size is invalid');
    }

    final nonce = combined.sublist(0, _nonceLength);
    final mac = combined.sublist(combined.length - _macLength);
    final cipherText = combined.sublist(
      _nonceLength,
      combined.length - _macLength,
    );

    final secretKey = SecretKey(keyBytes);
    final box = SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
    final plain = await _aes.decrypt(box, secretKey: secretKey);
    if (declaredSize is int && plain.length != declaredSize) {
      throw const FormatException('attachment plaintext size does not match');
    }
    return Uint8List.fromList(plain);
  }
}
