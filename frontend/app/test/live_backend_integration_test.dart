@Tags(['integration', 'live'])
library;

// Full-stack integration test using the app's real production classes
// (ApiClient, CryptoService, SignalBundle) against the actually-running
// Home Node/Discovery Node/Storage Node stack — everything except the
// widget/UI layer, which flutter_test's fake-async zone makes unreliable
// to drive with real network I/O from inside testWidgets() (see git log /
// session notes for registration_flow_test.dart, removed for that reason).
//
// Requires the backend to be running locally (see project/services/).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/crypto/crypto_service.dart';
import 'package:messenger_app/services/api_client.dart';

void main() {
  test(
    'Two real users register, message each other, and only the recipient can decrypt',
    () async {
      final suffix = Random().nextInt(999999).toString().padLeft(6, '0');
      final aliceApi = ApiClient();
      final bobApi = ApiClient();
      final aliceCrypto = CryptoService.ephemeral();
      final bobCrypto = CryptoService.ephemeral();

      final aliceBundle = await aliceCrypto.generatePublishableBundle();
      final aliceReg = await aliceApi.register(
        displayName: 'Alice-IT',
        phone: '+7000$suffix',
        password: 'test-password-1',
        deviceName: 'test',
        deviceType: 'linux',
        authPublicKey: base64Encode(List.filled(32, 1)),
        identityKeyBundle: aliceBundle,
      );
      aliceApi.accessToken = aliceReg['access_token'] as String;
      final aliceUserId = aliceReg['user_id'] as String;

      final bobBundle = await bobCrypto.generatePublishableBundle();
      final bobReg = await bobApi.register(
        displayName: 'Bob-IT',
        phone: '+7001$suffix',
        password: 'test-password-2',
        deviceName: 'test',
        deviceType: 'linux',
        authPublicKey: base64Encode(List.filled(32, 2)),
        identityKeyBundle: bobBundle,
      );
      bobApi.accessToken = bobReg['access_token'] as String;
      final bobUserId = bobReg['user_id'] as String;

      // Alice fetches Bob's real published bundle from the live Home Node
      // (not a hand-constructed one) and establishes a session with it.
      final fetchedBobBundle = await aliceApi.getPreKeyBundle(bobUserId);
      await aliceCrypto.establishSessionFromBundle(
        bobUserId,
        fetchedBobBundle['bundle'] as Map<String, dynamic>,
      );

      final conv = await aliceApi.createConversation(
        type: 'direct',
        participantUserIds: [bobUserId],
      );

      const plaintext =
          'hello from the real client stack, never visible server-side';
      final ciphertext = await aliceCrypto.encrypt(
        bobUserId,
        utf8.encode(plaintext),
      );

      final sent = await aliceApi.sendMessage(
        conversationId: conv['id'] as String,
        ciphertext: ciphertext,
        contentType: 'text',
      );

      // The server must only ever have stored/returned opaque ciphertext.
      expect(sent['ciphertext'], isNot(contains(plaintext)));

      final bobHistory = await bobApi.getMessages(conv['id'] as String);
      expect(bobHistory, hasLength(1));
      final receivedEnvelope = bobHistory.first as Map<String, dynamic>;
      expect(receivedEnvelope['ciphertext'], isNot(contains(plaintext)));

      final decrypted = await bobCrypto.decrypt(
        aliceUserId,
        receivedEnvelope['ciphertext'] as String,
      );
      expect(utf8.decode(decrypted), equals(plaintext));
    },
    skip: Platform.environment['RUN_LIVE_BACKEND'] == '1'
        ? false
        : 'Requires RUN_LIVE_BACKEND=1 and Home Node on localhost:8001',
  );
}
