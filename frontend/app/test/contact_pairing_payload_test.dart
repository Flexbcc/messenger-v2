import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/crypto/auth_keypair.dart';
import 'package:messenger_app/services/contact_pairing_payload.dart';
import 'package:messenger_app/services/contact_pairing_store.dart';
import 'package:messenger_app/services/local_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LocalSettingsStore.setActiveUser('owner');
  });

  test('QR contains only signed technical handshake fields', () async {
    final signer = await AuthKeyPair.loadOrCreate();
    final raw = await ContactPairingPayload.create(
      userId: '11111111-1111-4111-8111-111111111111',
      signer: signer,
      identityPublicKey: base64Encode(List<int>.filled(33, 7)),
      ttl: const Duration(minutes: 10),
      now: DateTime.utc(2026, 8, 1, 12),
    );
    final json = jsonDecode(raw) as Map<String, dynamic>;

    expect(json.keys, {
      'kind',
      'v',
      'user_id',
      'auth_key',
      'identity_key',
      'nonce',
      'expires_at',
      'signature',
    });
    for (final forbidden in [
      'display_name',
      'phone',
      'email',
      'username',
      'bio',
      'avatar',
    ]) {
      expect(json.containsKey(forbidden), isFalse);
    }

    final parsed = await ContactPairingPayload.parseAndVerify(
      raw,
      now: DateTime.utc(2026, 8, 1, 12, 5),
    );
    expect(parsed.userId, '11111111-1111-4111-8111-111111111111');
  });

  test('tampered or expired QR is rejected', () async {
    final signer = await AuthKeyPair.loadOrCreate();
    final raw = await ContactPairingPayload.create(
      userId: '11111111-1111-4111-8111-111111111111',
      signer: signer,
      identityPublicKey: base64Encode(List<int>.filled(33, 7)),
      ttl: const Duration(minutes: 10),
      now: DateTime.utc(2026, 8, 1, 12),
    );
    final tampered = jsonDecode(raw) as Map<String, dynamic>;
    tampered['user_id'] = '22222222-2222-4222-8222-222222222222';

    await expectLater(
      ContactPairingPayload.parseAndVerify(
        jsonEncode(tampered),
        now: DateTime.utc(2026, 8, 1, 12, 5),
      ),
      throwsFormatException,
    );
    await expectLater(
      ContactPairingPayload.parseAndVerify(
        raw,
        now: DateTime.utc(2026, 8, 1, 12, 11),
      ),
      throwsFormatException,
    );
  });

  test('verified public keys are stored only for the active account', () async {
    final signer = await AuthKeyPair.loadOrCreate();
    final raw = await ContactPairingPayload.create(
      userId: '11111111-1111-4111-8111-111111111111',
      signer: signer,
      identityPublicKey: base64Encode(List<int>.filled(33, 7)),
      ttl: const Duration(minutes: 10),
    );
    final payload = await ContactPairingPayload.parseAndVerify(raw);
    final store = ContactPairingStore();
    await store.save(payload);
    expect(await store.load(payload.userId), isNotNull);

    LocalSettingsStore.setActiveUser('other');
    expect(await store.load(payload.userId), isNull);
  });
}
