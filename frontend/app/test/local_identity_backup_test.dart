import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/crypto/auth_keypair.dart';
import 'package:messenger_app/crypto/crypto_service.dart';
import 'package:messenger_app/services/local_identity_backup.dart';
import 'package:messenger_app/services/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('local identity survives encrypted-backup payload round trip', () async {
    final auth = await AuthKeyPair.loadOrCreate();
    await CryptoService.loadOrCreate();
    await SessionStore().rememberIdentity(
      userId: 'user-1',
      deviceId: 'device-1',
      displayName: 'Alice',
    );
    final originalPublicKey = auth.publicKeyBase64;
    final backup = await LocalIdentityBackup.export();

    await AuthKeyPair.wipeLocal();
    await CryptoService.wipeLocalKeys();
    expect(await AuthKeyPair.existsLocally(), isFalse);

    await LocalIdentityBackup.restore(backup);
    final restored = await AuthKeyPair.loadOrCreate();
    final locator = await SessionStore().loadRememberedIdentity();
    expect(restored.publicKeyBase64, originalPublicKey);
    expect(locator?.deviceId, 'device-1');
  });
}
