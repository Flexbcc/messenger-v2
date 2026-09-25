import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/crypto/crypto_service.dart';
import 'package:messenger_app/security/device_crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    DeviceCrypto.instance.invalidateCache();
  });

  test(
    'recipient ratchet survives a full CryptoService reconstruction',
    () async {
      final alice = CryptoService.ephemeral();
      var bob = await CryptoService.loadOrCreate();
      final bobIdentity = bob.identityPublicKeyBase64;
      final bobBundle = await bob.generatePublishableBundle();

      await alice.establishSessionFromBundle('bob', bobBundle);
      final first = await alice.encrypt('bob', utf8.encode('before restart'));
      expect(utf8.decode(await bob.decrypt('alice', first)), 'before restart');

      // Model a terminated process: no CryptoService object and no cached local
      // database key survive. The new service must recover identity, prekeys and
      // Double Ratchet state from platform-backed persisted values.
      DeviceCrypto.instance.invalidateCache();
      bob = await CryptoService.loadOrCreate();
      expect(bob.identityPublicKeyBase64, bobIdentity);

      final second = await alice.encrypt('bob', utf8.encode('after restart'));
      expect(utf8.decode(await bob.decrypt('alice', second)), 'after restart');

      final reply = await bob.encrypt(
        'alice',
        utf8.encode('reply after restart'),
      );
      expect(
        utf8.decode(await alice.decrypt('bob', reply)),
        'reply after restart',
      );
    },
  );

  test('sender ratchet survives a full CryptoService reconstruction', () async {
    var alice = await CryptoService.loadOrCreate();
    final bob = CryptoService.ephemeral();
    final aliceIdentity = alice.identityPublicKeyBase64;

    await alice.establishSessionFromBundle(
      'bob',
      await bob.generatePublishableBundle(),
    );
    final first = await alice.encrypt('bob', utf8.encode('sender before'));
    expect(utf8.decode(await bob.decrypt('alice', first)), 'sender before');

    DeviceCrypto.instance.invalidateCache();
    alice = await CryptoService.loadOrCreate();
    expect(alice.identityPublicKeyBase64, aliceIdentity);

    final second = await alice.encrypt('bob', utf8.encode('sender after'));
    expect(utf8.decode(await bob.decrypt('alice', second)), 'sender after');
  });
}
