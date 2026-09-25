import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/core/theme/app_theme.dart';
import 'package:messenger_app/screens/managed_nodes_screen.dart';
import 'package:messenger_app/services/node_owner/managed_node.dart';
import 'package:messenger_app/services/node_owner/managed_node_registry.dart';
import 'package:messenger_app/services/node_owner/node_owner_api_client.dart';
import 'package:messenger_app/services/node_owner/node_owner_http_transport.dart';
import 'package:messenger_app/services/node_owner/node_owner_key_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows honest empty state and a locally named managed node', (
    tester,
  ) async {
    final keys = NodeOwnerKeyStore();
    final registry = ManagedNodeRegistry(keyStore: keys);
    final api = NodeOwnerApiClient(
      transport: _NoNetworkTransport(),
      keyStore: keys,
      registry: registry,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: ManagedNodesScreen(registry: registry, apiClient: api),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ноды ещё не подключены'), findsOneWidget);
    expect(find.text('Добавить ноду'), findsOneWidget);

    final key = await keys.createKey();
    await registry.add(
      ManagedNode(
        localLabel: 'Домашний сервер',
        nodeId: 'node-home',
        endpoints: const ['http://127.0.0.1:9443'],
        caFingerprint: '',
        ownerDeviceCertificate: {
          'node_id': 'node-home',
          'serial': 'serial-home',
          'role': 'owner',
        },
        keyAlias: key.keyAlias,
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await tester.pumpAndSettle();
    // Pull-to-refresh is intentionally explicit; recreate mirrors reopening.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: ManagedNodesScreen(registry: registry, apiClient: api),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Домашний сервер'), findsOneWidget);
    expect(find.text('node-home'), findsOneWidget);
  });
}

class _NoNetworkTransport implements NodeOwnerTransport {
  @override
  Future<NodeOwnerHttpResponse> send({
    required Uri uri,
    required String method,
    required Map<String, String> headers,
    required List<int> body,
    required String expectedCaFingerprint,
  }) {
    throw StateError('network is not expected in this widget test');
  }
}
