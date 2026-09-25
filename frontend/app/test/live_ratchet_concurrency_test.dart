@Tags(['integration', 'live'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/crypto/crypto_service.dart';
import 'package:messenger_app/services/api_client.dart';
import 'package:messenger_app/utils/crypto_serial_queue.dart';

void main() {
  test(
    'text and control payloads share one live per-device ratchet queue',
    () async {
      final suffix = Random.secure().nextInt(999999).toString().padLeft(6, '0');
      final aliceApi = ApiClient();
      final bobApi = ApiClient();
      final aliceCrypto = CryptoService.ephemeral();
      final bobCrypto = CryptoService.ephemeral();

      final aliceReg = await aliceApi.register(
        displayName: 'Alice-Ratchet-$suffix',
        phone: '+7110$suffix',
        password: 'test-password-1',
        deviceName: 'alice-live',
        deviceType: 'linux',
        authPublicKey: base64Encode(List<int>.filled(32, 11)),
        identityKeyBundle: await aliceCrypto.generatePublishableBundle(),
      );
      aliceApi.accessToken = aliceReg['access_token'] as String;
      final aliceUserId = aliceReg['user_id'] as String;
      final aliceDeviceId = aliceReg['device_id'] as String;

      final bobReg = await bobApi.register(
        displayName: 'Bob-Ratchet-$suffix',
        phone: '+7120$suffix',
        password: 'test-password-2',
        deviceName: 'bob-live',
        deviceType: 'linux',
        authPublicKey: base64Encode(List<int>.filled(32, 12)),
        identityKeyBundle: await bobCrypto.generatePublishableBundle(),
      );
      bobApi.accessToken = bobReg['access_token'] as String;
      final bobUserId = bobReg['user_id'] as String;
      final bobDeviceId = bobReg['device_id'] as String;

      final bobBundle = await aliceApi.getDevicePreKeyBundle(
        bobUserId,
        bobDeviceId,
      );
      await aliceCrypto.establishSessionFromBundle(
        bobUserId,
        bobBundle,
        deviceId: bobDeviceId,
      );

      final conversation = await aliceApi.createConversation(
        type: 'direct',
        participantUserIds: [bobUserId],
      );
      final conversationId = conversation['id'] as String;
      final queue = CryptoSerialQueue();
      final payloads = <({String body, String contentType})>[];
      for (var index = 1; index <= 100; index++) {
        payloads.add((body: 'text-$index', contentType: 'text'));
        if (index % 20 == 0) {
          payloads.add((
            body: '{"read_until":"$index"}',
            contentType: 'read_receipt',
          ));
        }
      }

      await Future.wait([
        for (var index = 0; index < payloads.length; index++)
          queue.run('direct:$bobUserId', () async {
            final ciphertext = await aliceCrypto.encrypt(
              bobUserId,
              utf8.encode(payloads[index].body),
              recipientDeviceId: bobDeviceId,
            );
            await aliceApi.sendMessage(
              conversationId: conversationId,
              ciphertext: ciphertext,
              contentType: payloads[index].contentType,
              clientMsgId: 'ratchet-$suffix-$index',
              deviceEnvelopes: [
                {'device_id': bobDeviceId, 'ciphertext': ciphertext},
              ],
            );
          }),
      ]);

      final history =
          (await bobApi.getMessages(conversationId, limit: 200)).toList()..sort(
            (left, right) => (left['created_at'] as String).compareTo(
              right['created_at'] as String,
            ),
          );
      expect(history, hasLength(payloads.length));
      for (var index = 0; index < history.length; index++) {
        final plaintext = await bobCrypto.decrypt(
          aliceUserId,
          history[index]['ciphertext'] as String,
          senderDeviceId: aliceDeviceId,
        );
        expect(utf8.decode(plaintext), payloads[index].body);
      }
    },
    skip: Platform.environment['RUN_LIVE_BACKEND'] == '1'
        ? false
        : 'Requires RUN_LIVE_BACKEND=1 and Home Node on localhost:8001',
  );
}
