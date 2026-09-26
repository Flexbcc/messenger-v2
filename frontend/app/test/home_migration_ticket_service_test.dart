import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/services/home_migration_ticket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'legacy account migration ticket signs the exact manifest hash',
    () async {
      final manifest = <String, dynamic>{
        'manifest_version': 1,
        'user': {'display_name': 'Alice', 'user_id': 'legacy-user'},
        'devices': [
          {'device_id': 'device-a', 'trusted': true},
        ],
      };
      // Python canonical_json(manifest) produces the same recursively sorted
      // representation, so this value also protects cross-language encoding.
      const manifestHash =
          'e0dbef5e9f70452ea97f7758cb1fbe3b4c00ee19523beeda9a7809f9b35a689e';
      final ticket = await const HomeMigrationTicketService().issue(
        networkId: 'ouo-cluster:test',
        userId: 'legacy-user',
        identityVersion: 1,
        routeEpoch: 7,
        fromHome: 'https://old.example',
        toHome: 'https://new.example',
        manifest: manifest,
        expectedManifestHash: manifestHash,
        now: DateTime.utc(2026, 9, 26, 16),
      );

      expect(ticket['device_manifest_hash'], manifestHash);
      expect(ticket['user_id'], 'legacy-user');
      final unsigned = Map<String, dynamic>.from(ticket)..remove('signature');
      final canonical = _canonicalValue(unsigned);
      final publicKey = SimplePublicKey(
        base64Decode(ticket['identity_public_key'] as String),
        type: KeyPairType.ed25519,
      );
      expect(
        await Ed25519().verify(
          utf8.encode('OUO/HOME_MIGRATION/v1\u0000$canonical'),
          signature: Signature(
            base64Decode(ticket['signature'] as String),
            publicKey: publicKey,
          ),
        ),
        isTrue,
      );
    },
  );

  test('manifest substitution is rejected before signing', () async {
    await expectLater(
      const HomeMigrationTicketService().issue(
        networkId: 'ouo-cluster:test',
        userId: 'legacy-user',
        identityVersion: 1,
        routeEpoch: 7,
        fromHome: 'https://old.example',
        toHome: 'https://new.example',
        manifest: {
          'manifest_version': 1,
          'devices': [],
          'user': {'user_id': 'attacker'},
        },
        expectedManifestHash: List.filled(64, '0').join(),
        now: DateTime.utc(2026, 9, 26, 16),
      ),
      throwsFormatException,
    );
  });
}

String _canonicalValue(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalValue(value[key])}').join(',')}}';
  }
  if (value is List) return '[${value.map(_canonicalValue).join(',')}]';
  return jsonEncode(value);
}
