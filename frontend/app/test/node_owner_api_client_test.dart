import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/services/node_owner/managed_node_registry.dart';
import 'package:messenger_app/services/node_owner/node_owner_api_client.dart';
import 'package:messenger_app/services/node_owner/node_owner_http_transport.dart';
import 'package:messenger_app/services/node_owner/node_owner_key_store.dart';
import 'package:messenger_app/services/node_owner/node_owner_pairing_payload.dart';
import 'package:messenger_app/services/node_owner/node_owner_request_signer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'client pairs, signs requests and erases its key after self-revocation',
    () async {
      final server = await _FakeOwnerNode.create();
      final pairing = NodeOwnerPairingPayload.parse(
        jsonEncode(server.pairingPayload),
        now: server.now,
      );
      final keys = NodeOwnerKeyStore();
      final registry = ManagedNodeRegistry(keyStore: keys);
      final client = NodeOwnerApiClient(
        transport: server,
        keyStore: keys,
        registry: registry,
        signer: NodeOwnerRequestSigner(keyStore: keys),
      );

      final node = await client.pair(pairing: pairing, localLabel: 'Моя нода');
      expect(node.nodeId, server.nodeId);
      expect(await keys.contains(node.keyAlias), isTrue);
      expect((await registry.list()).single.localLabel, 'Моя нода');

      final status = await client.status(node.nodeId);
      expect(status['status'], 'ok');
      expect(server.sawSignedStatus, isTrue);

      await client.revokeDevice(node.nodeId, node.certificateSerial);
      expect(server.sawSignedRevoke, isTrue);
      expect(await registry.list(), isEmpty);
      expect(await keys.contains(node.keyAlias), isFalse);
    },
  );

  test('tampered certificate never enters registry', () async {
    final server = await _FakeOwnerNode.create(tamperRole: true);
    final pairing = NodeOwnerPairingPayload.parse(
      jsonEncode(server.pairingPayload),
      now: server.now,
    );
    final registry = ManagedNodeRegistry();
    final client = NodeOwnerApiClient(transport: server, registry: registry);
    await expectLater(
      client.pair(pairing: pairing, localLabel: 'Подмена'),
      throwsFormatException,
    );
    expect(await registry.list(), isEmpty);
  });
}

class _FakeOwnerNode implements NodeOwnerTransport {
  _FakeOwnerNode._({
    required this.rootKeyPair,
    required this.rootPublicKey,
    required this.nodeId,
    required this.now,
    required this.tamperRole,
  });

  final SimpleKeyPair rootKeyPair;
  final String rootPublicKey;
  final String nodeId;
  final DateTime now;
  final bool tamperRole;
  bool sawSignedStatus = false;
  bool sawSignedRevoke = false;

  static Future<_FakeOwnerNode> create({bool tamperRole = false}) async {
    final root = await Ed25519().newKeyPair();
    final public = await root.extractPublicKey();
    final encoded = base64UrlEncode(public.bytes);
    return _FakeOwnerNode._(
      rootKeyPair: root,
      rootPublicKey: encoded,
      nodeId: NodeOwnerPairingPayload.nodeIdFromRootPublicKey(public.bytes),
      now: DateTime.now().toUtc(),
      tamperRole: tamperRole,
    );
  }

  Map<String, dynamic> get pairingPayload => {
    'kind': 'ouo_node_owner_pair',
    'version': 1,
    'protocol_version': 'ouo-owner-pair/1',
    'node_id': nodeId,
    'node_root_public_key': rootPublicKey,
    'management_endpoints': ['http://127.0.0.1:9443'],
    'management_ca_fingerprint': '',
    'pairing_id': '11111111-1111-4111-8111-111111111111',
    'pairing_secret': List.filled(43, 'x').join(),
    'role': 'owner',
    'expires_at': now.add(const Duration(minutes: 5)).toIso8601String(),
  };

  @override
  Future<NodeOwnerHttpResponse> send({
    required Uri uri,
    required String method,
    required Map<String, String> headers,
    required List<int> body,
    required String expectedCaFingerprint,
  }) async {
    if (uri.path == '/owner/v1/pair') {
      final request = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      final certificate = <String, dynamic>{
        'protocol_version': 'ouo-owner-device/1',
        'object_version': 1,
        'node_id': nodeId,
        'node_root_public_key': rootPublicKey,
        'device_id': '33333333-3333-4333-8333-333333333333',
        'device_public_key': request['device_public_key'],
        'role': 'owner',
        'serial': '22222222-2222-4222-8222-222222222222',
        'issued_at': now.subtract(const Duration(minutes: 1)).toIso8601String(),
        'valid_until': now.add(const Duration(days: 30)).toIso8601String(),
        'signature_algorithm': 'Ed25519',
      };
      final sorted = <String, dynamic>{};
      for (final key in certificate.keys.toList()..sort()) {
        sorted[key] = certificate[key];
      }
      final signature = await Ed25519().sign(
        utf8.encode('OUO/OWNER_DEVICE_CERT/v1\u0000${jsonEncode(sorted)}'),
        keyPair: rootKeyPair,
      );
      certificate['signature'] = base64UrlEncode(signature.bytes);
      if (tamperRole) certificate['role'] = 'viewer';
      return NodeOwnerHttpResponse(
        statusCode: 201,
        body: utf8.encode(jsonEncode({'certificate': certificate})),
      );
    }
    if (uri.path == '/owner/v1/status') {
      sawSignedStatus = headers['X-OUO-Owner-Request']?.isNotEmpty == true;
      return NodeOwnerHttpResponse(
        statusCode: 200,
        body: utf8.encode(jsonEncode({'status': 'ok', 'node_id': nodeId})),
      );
    }
    if (uri.path.endsWith('/revoke')) {
      sawSignedRevoke = headers['X-OUO-Owner-Request']?.isNotEmpty == true;
      return NodeOwnerHttpResponse(
        statusCode: 200,
        body: utf8.encode(jsonEncode({'status': 'revoked'})),
      );
    }
    return const NodeOwnerHttpResponse(statusCode: 404, body: []);
  }
}
