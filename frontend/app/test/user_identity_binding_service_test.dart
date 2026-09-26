import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/crypto/auth_keypair.dart';
import 'package:messenger_app/services/user_identity_binding_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('binding is signed by stable Identity Root and current DeviceKey', () async {
    final device = await AuthKeyPair.loadOrCreate();
    final binding = await const UserIdentityBindingService().issue(
      networkId: 'ouo-cluster:test',
      userId: 'user-a',
      deviceId: 'device-a',
      deviceKey: device,
      now: DateTime.utc(2026, 9, 26, 15),
    );
    final unsigned = Map<String, dynamic>.from(binding)
      ..remove('identity_signature')
      ..remove('device_signature');
    final sorted = <String, dynamic>{};
    for (final key in unsigned.keys.toList()..sort()) {
      sorted[key] = unsigned[key];
    }
    final payload = utf8.encode(
      'OUO/USER_IDENTITY_BINDING/v1\u0000${jsonEncode(sorted)}',
    );
    final algorithm = Ed25519();
    final identityPublic = SimplePublicKey(
      base64Decode(binding['identity_public_key'] as String),
      type: KeyPairType.ed25519,
    );
    final devicePublic = SimplePublicKey(
      base64Decode(binding['authorizing_device_public_key'] as String),
      type: KeyPairType.ed25519,
    );

    expect(
      await algorithm.verify(
        payload,
        signature: Signature(
          base64Decode(binding['identity_signature'] as String),
          publicKey: identityPublic,
        ),
      ),
      isTrue,
    );
    expect(
      await algorithm.verify(
        payload,
        signature: Signature(
          base64Decode(binding['device_signature'] as String),
          publicKey: devicePublic,
        ),
      ),
      isTrue,
    );

    final second = await const UserIdentityBindingService().issue(
      networkId: 'ouo-cluster:test',
      userId: 'user-a',
      deviceId: 'device-a',
      deviceKey: device,
      now: DateTime.utc(2026, 9, 26, 15, 1),
    );
    expect(second['identity_public_key'], binding['identity_public_key']);
  });
}
