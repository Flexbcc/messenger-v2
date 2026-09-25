import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/crypto/crypto_service.dart';
import 'package:messenger_app/utils/crypto_serial_queue.dart';

void main() {
  test('same Signal session never runs two mutations concurrently', () async {
    final queue = CryptoSerialQueue();
    var active = 0;
    var maximumActive = 0;
    final order = <int>[];

    await Future.wait([
      for (var i = 0; i < 20; i++)
        queue.run('direct:peer', () async {
          active += 1;
          maximumActive = active > maximumActive ? active : maximumActive;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          order.add(i);
          active -= 1;
        }),
    ]);

    expect(maximumActive, 1);
    expect(order, List<int>.generate(20, (index) => index));
  });

  test('queued concurrent ratchet encryptions all decrypt in order', () async {
    final alice = CryptoService.ephemeral();
    final bob = CryptoService.ephemeral();
    final queue = CryptoSerialQueue();

    await alice.establishSessionFromBundle(
      'bob',
      await bob.generatePublishableBundle(),
      deviceId: 'bob-device',
    );

    final ciphertexts = await Future.wait([
      for (var i = 0; i < 12; i++)
        queue.run(
          'direct:bob',
          () => alice.encrypt(
            'bob',
            utf8.encode('payload-$i'),
            recipientDeviceId: 'bob-device',
          ),
        ),
    ]);

    for (var i = 0; i < ciphertexts.length; i++) {
      final plaintext = await bob.decrypt(
        'alice',
        ciphertexts[i],
        senderDeviceId: 'alice-device',
      );
      expect(utf8.decode(plaintext), 'payload-$i');
    }
  });
}
