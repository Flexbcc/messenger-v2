import 'dart:convert';

import '../../security/secure_prefs.dart';
import 'managed_node.dart';
import 'node_owner_key_store.dart';

class ManagedNodeRegistry {
  ManagedNodeRegistry({SecurePrefs? securePrefs, NodeOwnerKeyStore? keyStore})
    : _securePrefs = securePrefs ?? SecurePrefs.instance,
      _keyStore = keyStore ?? NodeOwnerKeyStore(securePrefs: securePrefs);

  static const _registryKey = 'managed_nodes_registry_v1';
  final SecurePrefs _securePrefs;
  final NodeOwnerKeyStore _keyStore;

  Future<List<ManagedNode>> list() async {
    final raw = await _securePrefs.read(_registryKey);
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Invalid managed node registry');
    }
    return List.unmodifiable(
      decoded.map(
        (value) =>
            ManagedNode.fromJson(Map<String, dynamic>.from(value as Map)),
      ),
    );
  }

  Future<ManagedNode?> find(String nodeId) async {
    for (final node in await list()) {
      if (node.nodeId == nodeId) return node;
    }
    return null;
  }

  Future<void> add(ManagedNode node) async {
    final validated = ManagedNode.fromJson(node.toJson());
    final nodes = [...await list()];
    if (nodes.any((item) => item.nodeId == validated.nodeId)) {
      throw StateError('Эта нода уже добавлена');
    }
    if (nodes.any((item) => item.keyAlias == validated.keyAlias)) {
      throw StateError('Ключ управления уже привязан к другой ноде');
    }
    if (validated.ownerDeviceCertificate['node_id'] != validated.nodeId) {
      throw StateError('Сертификат принадлежит другой ноде');
    }
    nodes.add(validated);
    await _write(nodes);
  }

  Future<void> remove(String nodeId) async {
    final nodes = [...await list()];
    final index = nodes.indexWhere((node) => node.nodeId == nodeId);
    if (index < 0) return;
    final removed = nodes.removeAt(index);
    // Delete the private key before forgetting its alias. If secure deletion
    // fails, retain the registry entry so recovery/retry remains possible.
    await _keyStore.remove(removed.keyAlias);
    await _write(nodes);
  }

  Future<void> _write(List<ManagedNode> nodes) => _securePrefs.write(
    _registryKey,
    jsonEncode(nodes.map((node) => node.toJson()).toList()),
  );
}
