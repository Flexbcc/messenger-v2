import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/security/network_identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'failover nodes with the same trust anchor keep one network identity',
    () async {
      const anchor = 'ed25519:central-network-root';
      final fromA1 = await NetworkIdentity.idFromTrustAnchor(anchor);
      final fromA2 = await NetworkIdentity.idFromTrustAnchor(anchor);

      expect(fromA1, fromA2);
      final firstKey = await NetworkIdentity.loadOrCreateUserKey(fromA1);
      final afterFailover = await NetworkIdentity.loadOrCreateUserKey(fromA2);
      expect(afterFailover.fingerprint, firstKey.fingerprint);
      expect(afterFailover.publicKey, firstKey.publicKey);
    },
  );

  test('independent networks always receive independent user keys', () async {
    final central = await NetworkIdentity.idFromTrustAnchor(
      'ed25519:central-network-root',
    );
    final decentralized = await NetworkIdentity.idFromTrustAnchor(
      'ed25519:decentralized-network-root',
    );
    final centralKey = await NetworkIdentity.loadOrCreateUserKey(central);
    final decentralizedKey = await NetworkIdentity.loadOrCreateUserKey(
      decentralized,
    );

    expect(central, isNot(decentralized));
    expect(centralKey.publicKey, isNot(decentralizedKey.publicKey));
    expect(centralKey.fingerprint, isNot(decentralizedKey.fingerprint));
    expect(
      await centralKey.sign(utf8.encode('challenge')),
      isNot(await decentralizedKey.sign(utf8.encode('challenge'))),
    );
  });

  test(
    'account namespaces differ by network even for the same user id',
    () async {
      final central = await NetworkIdentity.idFromTrustAnchor('central');
      final decentralized = await NetworkIdentity.idFromTrustAnchor(
        'decentralized',
      );

      final a = NetworkIdentity.accountNamespace(
        networkId: central,
        userId: 'same-user-id',
      );
      final b = NetworkIdentity.accountNamespace(
        networkId: decentralized,
        userId: 'same-user-id',
      );
      expect(a, isNot(b));
      expect(a, isNot(contains('same-user-id')));
      expect(b, isNot(contains('same-user-id')));
    },
  );

  test('empty or malformed network identity inputs fail closed', () async {
    await expectLater(
      NetworkIdentity.idFromTrustAnchor('   '),
      throwsFormatException,
    );
    expect(
      () => NetworkIdentity.accountNamespace(networkId: '', userId: 'u'),
      throwsFormatException,
    );
    await expectLater(
      NetworkIdentity.loadOrCreateUserKey(''),
      throwsFormatException,
    );
  });
}
