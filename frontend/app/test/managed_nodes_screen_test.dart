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

  for (final size in const [Size(390, 844), Size(1440, 900)]) {
    testWidgets('owner controls remain usable at ${size.width.toInt()}px', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final keys = NodeOwnerKeyStore();
      final registry = ManagedNodeRegistry(keyStore: keys);
      final key = await keys.createKey();
      await registry.add(
        ManagedNode(
          localLabel: 'Управляемая нода',
          nodeId: 'node-managed',
          endpoints: const ['http://127.0.0.1:9443'],
          homeEndpoint: 'http://127.0.0.1:8001',
          caFingerprint: '',
          ownerDeviceCertificate: const {
            'node_id': 'node-managed',
            'serial': 'serial-managed',
            'role': 'owner',
          },
          keyAlias: key.keyAlias,
        ),
      );
      final api = _FakeManagementApi(registry: registry, keyStore: keys);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: ManagedNodesScreen(registry: registry, apiClient: api),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Управляемая нода'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Состояние'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Сервисы'),
        320,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.byIcon(Icons.restart_alt_outlined), findsWidgets);
      await tester.scrollUntilVisible(
        find.text('Роли и лимиты'),
        320,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Роли и лимиты'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Обновление ноды'),
        320,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Обновление ноды'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Подключение аккаунта'),
        320,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Подключение аккаунта'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
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

class _FakeManagementApi extends NodeOwnerApiClient {
  _FakeManagementApi({required super.registry, required super.keyStore})
    : super(transport: _NoNetworkTransport());

  @override
  Future<Map<String, dynamic>> status(String nodeId) async => {
    'status': 'ok',
    'version': '0.1.0',
    'roles': ['home', 'relay', 'storage', 'management'],
    'resources': {
      'cpu_count': 2,
      'load_average': [0.1, 0.2, 0.3],
      'memory': {'total_bytes': 4294967296, 'used_bytes': 1073741824},
      'disk': {'total_bytes': 34359738368, 'used_bytes': 8589934592},
    },
  };

  @override
  Future<List<Map<String, dynamic>>> devices(String nodeId) async => const [];

  @override
  Future<Map<String, dynamic>> diagnostics(String nodeId) async => {
    'checks': [
      {'name': 'state_writable', 'ok': true, 'detail': 'ok'},
    ],
  };

  @override
  Future<Map<String, dynamic>> config(String nodeId) async => {
    'roles': ['home', 'relay', 'storage', 'management'],
    'accept_invites': false,
    'max_users': 100,
    'max_storage_gb': 20,
    'max_connections': 1000,
    'transit_enabled': true,
  };

  @override
  Future<List<Map<String, dynamic>>> audit(String nodeId) async => const [];
}
