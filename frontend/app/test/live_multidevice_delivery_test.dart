@Tags(['integration', 'live'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/crypto/crypto_service.dart';
import 'package:messenger_app/services/api_client.dart';

void main() {
  test(
    'linked devices receive independent E2EE envelopes for one account',
    () async {
      final suffix = Random.secure().nextInt(999999).toString().padLeft(6, '0');
      final primaryApi = ApiClient();
      final linkedApi = ApiClient();
      final senderApi = ApiClient();
      final primaryCrypto = CryptoService.ephemeral();
      final linkedCrypto = CryptoService.ephemeral();
      final senderCrypto = CryptoService.ephemeral();

      final primaryReg = await primaryApi.register(
        displayName: 'Multi Recipient $suffix',
        phone: '+7130$suffix',
        password: 'test-password-1',
        deviceName: 'primary-desktop',
        deviceType: 'desktop',
        authPublicKey: base64Encode(List<int>.filled(32, 21)),
        identityKeyBundle: await primaryCrypto.generatePublishableBundle(),
      );
      primaryApi.accessToken = primaryReg['access_token'] as String;
      final recipientUserId = primaryReg['user_id'] as String;
      final primaryDeviceId = primaryReg['device_id'] as String;

      final link = await linkedApi.createDeviceLink(
        deviceName: 'linked-web',
        deviceType: 'web',
        authPublicKey: base64Encode(List<int>.filled(32, 22)),
        identityKeyBundle: await linkedCrypto.generatePublishableBundle(),
      );
      await primaryApi.approveDeviceLink(
        linkId: link['link_id'] as String,
        secret: link['secret'] as String,
      );
      final linkedSession = await linkedApi.pollDeviceLink(
        linkId: link['link_id'] as String,
        secret: link['secret'] as String,
      );
      expect(linkedSession['status'], 'approved');
      expect(linkedSession['user_id'], recipientUserId);
      linkedApi.accessToken = linkedSession['access_token'] as String;
      final linkedDeviceId = linkedSession['device_id'] as String;
      expect(linkedDeviceId, isNot(primaryDeviceId));

      final senderReg = await senderApi.register(
        displayName: 'Multi Sender $suffix',
        phone: '+7140$suffix',
        password: 'test-password-2',
        deviceName: 'sender-desktop',
        deviceType: 'desktop',
        authPublicKey: base64Encode(List<int>.filled(32, 23)),
        identityKeyBundle: await senderCrypto.generatePublishableBundle(),
      );
      senderApi.accessToken = senderReg['access_token'] as String;
      final senderUserId = senderReg['user_id'] as String;
      final senderDeviceId = senderReg['device_id'] as String;

      final devices = await senderApi.getUserDeviceBundles(recipientUserId);
      expect(devices.map((item) => item['device_id']).toSet(), {
        primaryDeviceId,
        linkedDeviceId,
      });

      const plaintext = 'one logical message, one envelope per device';
      final envelopes = <Map<String, String>>[];
      for (final deviceId in [primaryDeviceId, linkedDeviceId]) {
        final bundle = await senderApi.getDevicePreKeyBundle(
          recipientUserId,
          deviceId,
        );
        await senderCrypto.establishSessionFromBundle(
          recipientUserId,
          bundle,
          deviceId: deviceId,
        );
        envelopes.add({
          'device_id': deviceId,
          'ciphertext': await senderCrypto.encrypt(
            recipientUserId,
            utf8.encode(plaintext),
            recipientDeviceId: deviceId,
          ),
        });
      }
      expect(envelopes[0]['ciphertext'], isNot(envelopes[1]['ciphertext']));

      final conversation = await senderApi.createConversation(
        type: 'direct',
        participantUserIds: [recipientUserId],
      );
      final conversationId = conversation['id'] as String;
      await senderApi.sendMessage(
        conversationId: conversationId,
        ciphertext: envelopes.first['ciphertext']!,
        contentType: 'text',
        deviceEnvelopes: envelopes,
      );

      final primaryHistory = await primaryApi.getMessages(conversationId);
      final linkedHistory = await linkedApi.getMessages(conversationId);
      expect(primaryHistory, hasLength(1));
      expect(linkedHistory, hasLength(1));
      expect(
        primaryHistory.single['ciphertext'],
        envelopes.singleWhere(
          (item) => item['device_id'] == primaryDeviceId,
        )['ciphertext'],
      );
      expect(
        linkedHistory.single['ciphertext'],
        envelopes.singleWhere(
          (item) => item['device_id'] == linkedDeviceId,
        )['ciphertext'],
      );

      expect(
        utf8.decode(
          await primaryCrypto.decrypt(
            senderUserId,
            primaryHistory.single['ciphertext'] as String,
            senderDeviceId: senderDeviceId,
          ),
        ),
        plaintext,
      );
      expect(
        utf8.decode(
          await linkedCrypto.decrypt(
            senderUserId,
            linkedHistory.single['ciphertext'] as String,
            senderDeviceId: senderDeviceId,
          ),
        ),
        plaintext,
      );
    },
    skip: Platform.environment['RUN_LIVE_BACKEND'] == '1'
        ? false
        : 'Requires RUN_LIVE_BACKEND=1 and Home Node on localhost:8001',
  );
}
