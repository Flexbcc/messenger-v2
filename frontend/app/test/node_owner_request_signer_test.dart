import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/security/crypto_encoding.dart';
import 'package:messenger_app/services/node_owner/managed_node.dart';
import 'package:messenger_app/services/node_owner/node_owner_key_store.dart';
import 'package:messenger_app/services/node_owner/node_owner_request_signer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'signed request binds target/body and reserves unique sequences',
    () async {
      final keyStore = NodeOwnerKeyStore();
      final key = await keyStore.createKey();
      final node = ManagedNode(
        localLabel: 'Test',
        nodeId: 'node-a',
        endpoints: const ['http://127.0.0.1:9443'],
        caFingerprint: '',
        ownerDeviceCertificate: {
          'node_id': 'node-a',
          'serial': 'certificate-1',
          'device_public_key': key.publicKey,
        },
        keyAlias: key.keyAlias,
      );
      final signer = NodeOwnerRequestSigner(keyStore: keyStore);
      final signed = await Future.wait([
        signer.sign(
          node: node,
          method: 'post',
          path: '/owner/v1/action',
          body: utf8.encode('{"x":1}'),
          now: DateTime.utc(2026, 9, 24, 12),
        ),
        signer.sign(
          node: node,
          method: 'get',
          path: '/owner/v1/status',
          body: const [],
          now: DateTime.utc(2026, 9, 24, 12),
        ),
      ]);
      expect(signed.map((item) => item.sequence).toSet(), {0, 1});

      final paddedHeader = signed.first.headerValue.padRight(
        ((signed.first.headerValue.length + 3) ~/ 4) * 4,
        '=',
      );
      final decoded = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(base64Url.decode(paddedHeader))) as Map,
      );
      expect(decoded['method'], 'POST');
      expect(decoded['path'], '/owner/v1/action');
      expect(
        decoded['body_sha256'],
      '5041bf1f713df204784353e82f6a4a535931cb64f1f4b4a5aeaffcb720918b22',
      );
      final signature = decodeBase64Exact(
        decoded.remove('signature').toString(),
        expectedBytes: 64,
        field: 'signature',
        urlSafe: true,
      );
      final sorted = <String, dynamic>{};
      for (final field in decoded.keys.toList()..sort()) {
        sorted[field] = decoded[field];
      }
      final valid = await Ed25519().verify(
        utf8.encode('OUO/OWNER_REQUEST/v1\u0000${jsonEncode(sorted)}'),
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(
            decodeBase64Exact(
              key.publicKey,
              expectedBytes: 32,
              field: 'public key',
              urlSafe: true,
            ),
            type: KeyPairType.ed25519,
          ),
        ),
      );
      expect(valid, isTrue);
    },
  );
}
