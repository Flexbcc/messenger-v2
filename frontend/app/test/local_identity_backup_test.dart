import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:messenger_app/crypto/auth_keypair.dart';
import 'package:messenger_app/crypto/crypto_service.dart';
import 'package:messenger_app/security/device_crypto.dart';
import 'package:messenger_app/services/local_identity_backup.dart';
import 'package:messenger_app/services/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('local identity survives encrypted-backup payload round trip', () async {
    final auth = await AuthKeyPair.loadOrCreate();
    var localCrypto = await CryptoService.loadOrCreate();
    final remoteCrypto = CryptoService.ephemeral();
    await localCrypto.establishSessionFromBundle(
      'remote-user',
      await remoteCrypto.generatePublishableBundle(),
    );
    final beforeBackup = await localCrypto.encrypt(
      'remote-user',
      utf8.encode('before backup'),
    );
    expect(
      utf8.decode(await remoteCrypto.decrypt('local-user', beforeBackup)),
      'before backup',
    );
    await DeviceCrypto.instance.exportKey();
    await SessionStore().rememberIdentity(
      userId: 'user-1',
      deviceId: 'device-1',
      displayName: 'Alice',
    );
    expect(await AuthKeyPair.exportSeed(), isNotNull);
    expect(await SessionStore().loadRememberedIdentity(), isNotNull);
    final originalPublicKey = auth.publicKeyBase64;
    final backup = await LocalIdentityBackup.export();

    await AuthKeyPair.wipeLocal();
    await CryptoService.wipeLocalKeys();
    await DeviceCrypto.instance.wipeLocalKey();
    await SessionStore().forgetIdentity();
    expect(await AuthKeyPair.existsLocally(), isFalse);

    await LocalIdentityBackup.restore(backup);
    final restored = await AuthKeyPair.loadOrCreate();
    localCrypto = await CryptoService.loadOrCreate();
    final locator = await SessionStore().loadRememberedIdentity();
    expect(restored.publicKeyBase64, originalPublicKey);
    expect(locator?.deviceId, 'device-1');

    // The backup contains the ratchet state, not only long-term identity.
    final replyAfterRestore = await remoteCrypto.encrypt(
      'local-user',
      utf8.encode('after restore'),
    );
    expect(
      utf8.decode(await localCrypto.decrypt('remote-user', replyAfterRestore)),
      'after restore',
    );
    final outboundAfterRestore = await localCrypto.encrypt(
      'remote-user',
      utf8.encode('restored sender'),
    );
    expect(
      utf8.decode(
        await remoteCrypto.decrypt('local-user', outboundAfterRestore),
      ),
      'restored sender',
    );
  });
}
