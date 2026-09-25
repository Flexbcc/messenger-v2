@Tags(['integration', 'live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/crypto/crypto_service.dart';
import 'package:messenger_app/services/api_client.dart';
import 'package:messenger_app/services/realtime_service.dart';

void main() {
  test(
    'online recipient receives and decrypts message over persistent WebSocket',
    () async {
      final suffix = Random.secure().nextInt(999999).toString().padLeft(6, '0');
      final senderApi = ApiClient();
      final recipientApi = ApiClient();
      final senderCrypto = CryptoService.ephemeral();
      final recipientCrypto = CryptoService.ephemeral();
      final realtime = RealtimeService();

      final senderReg = await senderApi.register(
        displayName: 'Realtime Sender $suffix',
        phone: '+7150$suffix',
        password: 'test-password-1',
        deviceName: 'sender-web',
        deviceType: 'web',
        authPublicKey: base64Encode(List<int>.filled(32, 31)),
        identityKeyBundle: await senderCrypto.generatePublishableBundle(),
      );
      senderApi.accessToken = senderReg['access_token'] as String;
      final senderUserId = senderReg['user_id'] as String;
      final senderDeviceId = senderReg['device_id'] as String;

      final recipientReg = await recipientApi.register(
        displayName: 'Realtime Recipient $suffix',
        phone: '+7160$suffix',
        password: 'test-password-2',
        deviceName: 'recipient-desktop',
        deviceType: 'desktop',
        authPublicKey: base64Encode(List<int>.filled(32, 32)),
        identityKeyBundle: await recipientCrypto.generatePublishableBundle(),
      );
      recipientApi.accessToken = recipientReg['access_token'] as String;
      final recipientUserId = recipientReg['user_id'] as String;
      final recipientDeviceId = recipientReg['device_id'] as String;

      final connected = Completer<void>();
      realtime.onConnected = () {
        if (!connected.isCompleted) connected.complete();
      };
      realtime.connect(recipientReg['access_token'] as String);

      try {
        await connected.future.timeout(const Duration(seconds: 5));
        expect(realtime.isConnected, isTrue);

        final bundle = await senderApi.getDevicePreKeyBundle(
          recipientUserId,
          recipientDeviceId,
        );
        await senderCrypto.establishSessionFromBundle(
          recipientUserId,
          bundle,
          deviceId: recipientDeviceId,
        );
        final conversation = await senderApi.createConversation(
          type: 'direct',
          participantUserIds: [recipientUserId],
        );
        final conversationId = conversation['id'] as String;
        const plaintext = 'persistent websocket delivery';
        final ciphertext = await senderCrypto.encrypt(
          recipientUserId,
          utf8.encode(plaintext),
          recipientDeviceId: recipientDeviceId,
        );

        final eventFuture = realtime.messages.firstWhere(
          (event) =>
              event['type'] == 'new_message' &&
              event['message'] is Map &&
              (event['message'] as Map)['conversation_id'] == conversationId,
        );
        final stopwatch = Stopwatch()..start();
        await senderApi.sendMessage(
          conversationId: conversationId,
          ciphertext: ciphertext,
          contentType: 'text',
          deviceEnvelopes: [
            {'device_id': recipientDeviceId, 'ciphertext': ciphertext},
          ],
        );
        final event = await eventFuture.timeout(const Duration(seconds: 5));
        stopwatch.stop();
        // Kept in live-test output as performance evidence; never contains
        // identifiers, tokens, ciphertext or plaintext.
        // ignore: avoid_print
        print('realtime_delivery_ms=${stopwatch.elapsedMilliseconds}');
        final message = Map<String, dynamic>.from(event['message'] as Map);
        expect(message['ciphertext'], ciphertext);
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
        expect(
          utf8.decode(
            await recipientCrypto.decrypt(
              senderUserId,
              message['ciphertext'] as String,
              senderDeviceId: senderDeviceId,
            ),
          ),
          plaintext,
        );
      } finally {
        realtime.disconnect();
      }
    },
    skip: Platform.environment['RUN_LIVE_BACKEND'] == '1'
        ? false
        : 'Requires RUN_LIVE_BACKEND=1 and Home Node on localhost:8001',
  );
}
