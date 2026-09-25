import 'dart:convert';

import 'managed_node.dart';
import 'managed_node_registry.dart';
import 'node_owner_http_transport.dart';
import 'node_owner_key_store.dart';
import 'node_owner_pairing_payload.dart';
import 'node_owner_request_signer.dart';
import 'node_owner_transport_factory.dart';
import 'owner_device_certificate.dart';

class NodeOwnerApiException implements Exception {
  const NodeOwnerApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class NodeOwnerApiClient {
  NodeOwnerApiClient({
    NodeOwnerTransport? transport,
    NodeOwnerKeyStore? keyStore,
    ManagedNodeRegistry? registry,
    NodeOwnerRequestSigner? signer,
  }) : _transport = transport ?? createNodeOwnerTransport(),
       _keyStore = keyStore ?? NodeOwnerKeyStore(),
       _registry = registry ?? ManagedNodeRegistry(),
       _signer = signer ?? NodeOwnerRequestSigner();

  final NodeOwnerTransport _transport;
  final NodeOwnerKeyStore _keyStore;
  final ManagedNodeRegistry _registry;
  final NodeOwnerRequestSigner _signer;

  Future<ManagedNode> pair({
    required NodeOwnerPairingPayload pairing,
    required String localLabel,
  }) async {
    final key = await _keyStore.createKey();
    try {
      final body = utf8.encode(
        jsonEncode({
          'pairing_id': pairing.pairingId,
          'pairing_secret': pairing.pairingSecret,
          'device_public_key': key.publicKey,
        }),
      );
      final response = await _transport.send(
        uri: _uri(pairing.managementEndpoints.first, '/owner/v1/pair'),
        method: 'POST',
        headers: const {'Content-Type': 'application/json'},
        body: body,
        expectedCaFingerprint: pairing.managementCaFingerprint,
      );
      if (response.statusCode != 201) {
        throw NodeOwnerApiException(
          'Нода отклонила одноразовое сопряжение',
          statusCode: response.statusCode,
        );
      }
      final responseJson = response.jsonObject();
      final certificateRaw = responseJson['certificate'];
      if (certificateRaw is! Map) {
        throw const FormatException('Нода не вернула owner-сертификат');
      }
      final certificate = await OwnerDeviceCertificate.parseAndVerify(
        Map<String, dynamic>.from(certificateRaw),
        expectedNodeId: pairing.nodeId,
        expectedRootPublicKey: pairing.nodeRootPublicKey,
        expectedDevicePublicKey: key.publicKey,
      );
      final node = ManagedNode(
        localLabel: localLabel.trim().isEmpty
            ? pairing.nodeId
            : localLabel.trim(),
        nodeId: pairing.nodeId,
        endpoints: pairing.managementEndpoints
            .map((endpoint) => endpoint.toString())
            .toList(growable: false),
        caFingerprint: pairing.managementCaFingerprint,
        ownerDeviceCertificate: certificate.json,
        keyAlias: key.keyAlias,
      );
      await _registry.add(node);
      return node;
    } catch (_) {
      await _keyStore.remove(key.keyAlias);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> status(String nodeId) async {
    final node = await _requireNode(nodeId);
    return _signedJson(node: node, method: 'GET', path: '/owner/v1/status');
  }

  Future<List<Map<String, dynamic>>> devices(String nodeId) async {
    final node = await _requireNode(nodeId);
    final response = await _signedJson(
      node: node,
      method: 'GET',
      path: '/owner/v1/devices',
    );
    final values = response['devices'];
    if (values is! List) {
      throw const FormatException('Некорректный список устройств');
    }
    return values
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList(growable: false);
  }

  Future<void> revokeDevice(String nodeId, String serial) async {
    final node = await _requireNode(nodeId);
    await _signedJson(
      node: node,
      method: 'POST',
      path: '/owner/v1/devices/$serial/revoke',
    );
    if (serial == node.certificateSerial) {
      await _registry.remove(nodeId);
      await _keyStore.remove(node.keyAlias);
    }
  }

  Future<Map<String, dynamic>> _signedJson({
    required ManagedNode node,
    required String method,
    required String path,
    List<int> body = const [],
  }) async {
    final signed = await _signer.sign(
      node: node,
      method: method,
      path: path,
      body: body,
    );
    final response = await _transport.send(
      uri: _uri(Uri.parse(node.endpoints.first), path),
      method: method,
      headers: {'X-OUO-Owner-Request': signed.headerValue},
      body: body,
      expectedCaFingerprint: node.caFingerprint,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NodeOwnerApiException(
        'Management API отклонил запрос',
        statusCode: response.statusCode,
      );
    }
    return response.jsonObject();
  }

  Future<ManagedNode> _requireNode(String nodeId) async {
    final node = await _registry.find(nodeId);
    if (node == null) throw const NodeOwnerApiException('Нода не добавлена');
    return node;
  }

  static Uri _uri(Uri endpoint, String path) =>
      endpoint.replace(path: path, query: null, fragment: null);
}
