import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/crypto/media_crypto.dart';

void main() {
  test(
    'photo is encrypted before storage and decrypts only with E2EE pointer',
    () async {
      // PNG signature plus deterministic payload: enough to prove that the
      // transport/storage bytes are not the original image bytes.
      final photo = Uint8List.fromList([
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
        ...List<int>.generate(512, (index) => index & 0xff),
      ]);

      final (ciphertext, pointer) = await MediaCrypto.encrypt(
        photo,
        filename: 'photo.png',
        mime: 'image/png',
      );

      expect(ciphertext, isNot(photo));
      expect(ciphertext.length, photo.length + 28); // nonce + AEAD tag
      expect(pointer['filename'], 'photo.png');
      expect(pointer['mime'], 'image/png');
      expect(pointer['size'], photo.length);
      expect(await MediaCrypto.decrypt(ciphertext, pointer), photo);

      final withoutConversationKey = Map<String, dynamic>.from(pointer)
        ..remove('key');
      expect(
        () => MediaCrypto.decrypt(ciphertext, withoutConversationKey),
        throwsFormatException,
      );

      final tampered = Uint8List.fromList(ciphertext)..[20] ^= 0x01;
      expect(
        () => MediaCrypto.decrypt(tampered, pointer),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    },
  );
}
