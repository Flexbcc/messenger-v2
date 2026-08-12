// Verifies real sender-key group encryption (0301_GROUP_MESSAGING.md):
// Alice distributes her sender key to Bob and Carol pairwise, then a
// message Alice encrypts once is decryptable by both — and NOT decryptable
// by someone who never received the distribution.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/crypto/crypto_service.dart';

void main() {
  test(
    'One sender-key encryption is decryptable by every member who received the distribution',
    () async {
      const groupId = 'group-1';
      final alice = CryptoService.ephemeral();
      final bob = CryptoService.ephemeral();
      final carol = CryptoService.ephemeral();
      final eve = CryptoService.ephemeral(); // never gets the distribution

      // Alice creates her sender key and "distributes" it directly (bypassing
      // the pairwise 1:1 transport, which is already covered by
      // crypto_roundtrip_test.dart — this test focuses on the group cipher).
      final distributionB64 = await alice.createGroupSenderKeyDistribution(
        groupId,
        'alice',
      );
      await bob.processGroupSenderKeyDistribution(
        groupId,
        'alice',
        distributionB64,
      );
      await carol.processGroupSenderKeyDistribution(
        groupId,
        'alice',
        distributionB64,
      );

      const plaintext = 'hello group, one ciphertext for everyone';
      final ciphertext = await alice.encryptGroup(
        groupId,
        'alice',
        utf8.encode(plaintext),
      );

      expect(
        utf8.decode(await bob.decryptGroup(groupId, 'alice', ciphertext)),
        equals(plaintext),
      );
      expect(
        utf8.decode(await carol.decryptGroup(groupId, 'alice', ciphertext)),
        equals(plaintext),
      );

      var threw = false;
      try {
        await eve.decryptGroup(groupId, 'alice', ciphertext);
      } catch (_) {
        threw = true;
      }
      expect(
        threw,
        isTrue,
        reason:
            'Eve never received the distribution and must not be able to decrypt',
      );

      // Ratcheting: a second message must still decrypt correctly for members
      // who already have the sender key (no redistribution needed).
      const second = 'second message, same sender key, ratcheted forward';
      final ciphertext2 = await alice.encryptGroup(
        groupId,
        'alice',
        utf8.encode(second),
      );
      expect(
        utf8.decode(await bob.decryptGroup(groupId, 'alice', ciphertext2)),
        equals(second),
      );
    },
  );
}
