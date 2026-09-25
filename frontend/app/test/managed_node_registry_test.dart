import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/services/node_owner/managed_node.dart';
import 'package:messenger_app/services/node_owner/managed_node_registry.dart';
import 'package:messenger_app/services/node_owner/node_owner_key_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Map<String, dynamic> certificate(String nodeId, String serial) => {
    'node_id': nodeId,
    'serial': serial,
    'role': 'owner',
  };

  test('registry keeps multiple nodes with distinct device keys', () async {
    final keys = NodeOwnerKeyStore();
    final registry = ManagedNodeRegistry(keyStore: keys);
    final firstKey = await keys.createKey();
    final secondKey = await keys.createKey();
    expect(firstKey.keyAlias, isNot(secondKey.keyAlias));
    expect(firstKey.publicKey, isNot(secondKey.publicKey));

    await registry.add(
      ManagedNode(
        localLabel: 'Дом',
        nodeId: 'node-a',
        endpoints: const ['https://100.64.0.2:9443'],
        caFingerprint: 'sha256:aa',
        ownerDeviceCertificate: certificate('node-a', 'serial-a'),
        keyAlias: firstKey.keyAlias,
      ),
    );
    await registry.add(
      ManagedNode(
        localLabel: 'Резерв',
        nodeId: 'node-b',
        endpoints: const ['https://100.64.0.3:9443'],
        caFingerprint: 'sha256:bb',
        ownerDeviceCertificate: certificate('node-b', 'serial-b'),
        keyAlias: secondKey.keyAlias,
      ),
    );

    final restored = await registry.list();
    expect(restored.map((node) => node.nodeId), ['node-a', 'node-b']);
    expect(restored.map((node) => node.keyAlias).toSet(), hasLength(2));
  });

  test('cross-node certificate and duplicate key alias are rejected', () async {
    final keys = NodeOwnerKeyStore();
    final registry = ManagedNodeRegistry(keyStore: keys);
    final key = await keys.createKey();
    await registry.add(
      ManagedNode(
        localLabel: 'A',
        nodeId: 'node-a',
        endpoints: const ['http://127.0.0.1:9443'],
        caFingerprint: '',
        ownerDeviceCertificate: certificate('node-a', 'serial-a'),
        keyAlias: key.keyAlias,
      ),
    );
    await expectLater(
      registry.add(
        ManagedNode(
          localLabel: 'B',
          nodeId: 'node-b',
          endpoints: const ['https://100.64.0.3:9443'],
          caFingerprint: 'sha256:bb',
          ownerDeviceCertificate: certificate('node-b', 'serial-b'),
          keyAlias: key.keyAlias,
        ),
      ),
      throwsStateError,
    );
    expect(
      () => ManagedNode.fromJson({
        'local_label': 'Подмена',
        'node_id': 'node-b',
        'endpoints': ['https://100.64.0.3:9443'],
        'ca_fingerprint': 'sha256:bb',
        'owner_device_certificate': certificate('node-a', 'serial-x'),
        'key_alias': 'key-x',
      }),
      throwsFormatException,
    );
  });

  test('non-loopback plaintext management endpoint is rejected', () {
    expect(
      () => ManagedNode.fromJson({
        'local_label': 'Unsafe',
        'node_id': 'node-a',
        'endpoints': ['http://192.168.1.10:9443'],
        'ca_fingerprint': '',
        'owner_device_certificate': certificate('node-a', 'serial-a'),
        'key_alias': 'key-a',
      }),
      throwsFormatException,
    );
  });
}
