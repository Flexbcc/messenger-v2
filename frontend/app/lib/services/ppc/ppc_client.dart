// Direct-mode PPC client — HTTP contract in storage-app/docs/WIRE.md.
//
// Pairing flow (QR payload v2): storage-app/docs/PAIRING-FLOWS.md.

import 'dart:convert';

import '../../crypto/auth_keypair.dart';
import '../settings_runtime.dart';
import 'ppc_mdns.dart';
import 'ppc_payload.dart';
import 'ppc_signing.dart';
import 'ppc_transport.dart';
import 'ppc_vault.dart';

class PpcException implements Exception {
  PpcException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => 'PpcException($statusCode): $message';
}

/// Phone-side PPC peer for direct-mode storage on a home PC (storage-app).
class PpcClient {
  PpcClient._({
    required AuthKeyPair authKeyPair,
    required String nodeId,
    required String deviceName,
    PpcTransport? transport,
    String? storagePubkey,
  }) : _nodeId = nodeId,
       _deviceName = deviceName,
       _signer = PpcSigner(authKeyPair: authKeyPair, nodeId: nodeId),
       _transport = transport,
       _storagePubkey = storagePubkey;

  factory PpcClient.fromAuth({
    required AuthKeyPair authKeyPair,
    required String nodeId,
    String deviceName = 'phone',
  }) {
    return PpcClient._(
      authKeyPair: authKeyPair,
      nodeId: nodeId,
      deviceName: deviceName,
    );
  }

  final String _nodeId;
  final String _deviceName;
  final PpcSigner _signer;
  PpcTransport? _transport;
  String? _storagePubkey;

  String? get storagePubkey => _storagePubkey;
  bool get isPaired => _transport != null && _storagePubkey != null;

  /// Restore transport from persisted vault state.
  Future<bool> restoreFromVault({PpcVault? vault}) async {
    final state = await (vault ?? PpcVault()).load();
    if (state == null) return false;
    _storagePubkey = state.storagePubkey;
    _transport = await _transportFromVault(state);
    return _transport != null;
  }

  /// Rebuild transport from vault (e.g. after external route changes).
  /// Composite failover is handled internally; this resets transport instances.
  Future<bool> rebuildTransportFromVault({PpcVault? vault}) async {
    return restoreFromVault(vault: vault);
  }

  /// Parse QR payload, resolve route (LAN → mDNS → relay), pair, and persist to vault.
  Future<PpcPairResult> resolveAndPair(
    String payloadJson, {
    String? name,
    PpcVault? vault,
  }) async {
    final payload = PpcPairingPayload.parse(payloadJson);
    final peerName = name ?? _deviceName;
    final peerPubkey = _signer.publicKeyWire;
    final pairBody = jsonEncode({
      'code': payload.code,
      'peer_pubkey': peerPubkey,
      'node_id': _nodeId,
      'name': peerName,
    });
    final pairBytes = utf8.encode(pairBody);
    final pairHeaders = {'Content-Type': 'application/json'};

    final errors = <String>[];
    Map<String, dynamic>? pairResponse;
    PpcRouteKind? routeKind;
    String? lanHint;
    final relayReach = payload.reach.relay;
    String? relayUrl;
    String? storageNodeId;
    if (relayReach != null && relayReach.isComplete) {
      relayUrl = relayReach.relayUrl;
      storageNodeId = relayReach.storageNodeId;
    }

    for (final hint in payload.reach.lanHints) {
      try {
        final base = parseLanBase(hint);
        final transport = LanPpcTransport(baseUri: base, signer: _signer);
        final resp = await transport.request(
          method: 'POST',
          path: '/ppc/pair',
          headers: pairHeaders,
          body: pairBytes,
          signed: false,
        );
        pairResponse = _decodePairResponse(resp);
        routeKind = PpcRouteKind.lan;
        lanHint = hint;
        break;
      } on PpcException catch (e) {
        errors.add('lan($hint): ${e.message}');
      } catch (e) {
        errors.add('lan($hint): $e');
      }
    }

    final mdnsService = payload.reach.mdns?.trim();
    if (pairResponse == null && mdnsService != null && mdnsService.isNotEmpty) {
      final mdnsHints = await discoverPpcLanHints(serviceType: mdnsService);
      for (final hint in mdnsHints) {
        try {
          final base = parseLanBase(hint);
          final transport = LanPpcTransport(baseUri: base, signer: _signer);
          final resp = await transport.request(
            method: 'POST',
            path: '/ppc/pair',
            headers: pairHeaders,
            body: pairBytes,
            signed: false,
          );
          pairResponse = _decodePairResponse(resp);
          routeKind = PpcRouteKind.lan;
          lanHint = hint;
          break;
        } on PpcException catch (e) {
          errors.add('mdns($hint): ${e.message}');
        } catch (e) {
          errors.add('mdns($hint): $e');
        }
      }
    }

    final relay = payload.reach.relay;
    final allowRelays = await SettingsRuntime.instance.nodeAllowRelays();
    if (pairResponse == null &&
        allowRelays &&
        relay != null &&
        relay.isComplete) {
      try {
        final transport = RelayPpcTransport(
          relayUrl: relay.relayUrl,
          storageNodeId: relay.storageNodeId,
          signer: _signer,
        );
        final resp = await transport.request(
          method: 'POST',
          path: '/ppc/pair',
          headers: pairHeaders,
          body: pairBytes,
          signed: false,
        );
        pairResponse = _decodePairResponse(resp);
        routeKind = PpcRouteKind.relay;
      } on PpcException catch (e) {
        errors.add('relay: ${e.message}');
      } catch (e) {
        errors.add('relay: $e');
      }
    }

    if (pairResponse == null || routeKind == null) {
      throw PpcException(
        0,
        errors.isEmpty ? 'no route to storage-app' : errors.join('; '),
      );
    }

    final storagePubkey = pairResponse['storage_pubkey'] as String;
    if (!storagePubkey.startsWith('ed25519:')) {
      throw PpcException(0, 'response missing storage_pubkey');
    }

    _storagePubkey = storagePubkey;
    _transport = await _buildTransport(
      lanHint: lanHint,
      relayUrl: allowRelays ? relayUrl : null,
      storageNodeId: storageNodeId,
    );
    final result = PpcPairResult(
      storagePubkey: storagePubkey,
      routeKind: routeKind,
      lanHint: lanHint,
      relayUrl: relayUrl,
      storageNodeId: storageNodeId,
      fingerprint: payload.fingerprint,
    );

    await (vault ?? PpcVault()).save(result: result, peerNodeId: _nodeId);
    return result;
  }

  /// PUT ciphertext blob at content-addressed `key` (hex SHA-256).
  Future<void> put({
    required String userId,
    required String key,
    required List<int> ciphertext,
  }) async {
    final transport = _requireTransport();
    final path = '/ppc/blob/$userId/$key';
    final resp = await transport.request(
      method: 'PUT',
      path: path,
      headers: {'Content-Type': 'application/octet-stream'},
      body: ciphertext,
    );
    if (resp.statusCode == 413) {
      throw PpcException(413, _errorDetail(resp.body) ?? 'quota_exceeded');
    }
    if (resp.statusCode == 422) {
      throw PpcException(422, _errorDetail(resp.body) ?? 'integrity');
    }
    _throwOnError(resp, allowed: {200});
  }

  /// GET blob bytes; null when not found (404).
  Future<List<int>?> get({required String userId, required String key}) async {
    final transport = _requireTransport();
    final path = '/ppc/blob/$userId/$key';
    final resp = await transport.request(method: 'GET', path: path);
    if (resp.statusCode == 404) return null;
    _throwOnError(resp, allowed: {200});
    return resp.body;
  }

  /// DELETE blob (idempotent — 404 treated as success).
  Future<void> delete({required String userId, required String key}) async {
    final transport = _requireTransport();
    final path = '/ppc/blob/$userId/$key';
    final resp = await transport.request(method: 'DELETE', path: path);
    if (resp.statusCode == 404 || resp.statusCode == 200) return;
    _throwOnError(resp, allowed: {200});
  }

  PpcTransport _requireTransport() {
    final transport = _transport;
    if (transport == null) {
      throw PpcException(
        0,
        'not paired — call resolveAndPair or restoreFromVault',
      );
    }
    return transport;
  }

  Future<PpcTransport?> _transportFromVault(PpcVaultState state) {
    return _buildTransport(
      lanHint: state.lanHint,
      relayUrl: state.relayUrl,
      storageNodeId: state.storageNodeId,
    );
  }

  Future<PpcTransport?> _buildTransport({
    String? lanHint,
    String? relayUrl,
    String? storageNodeId,
  }) async {
    final transports = <PpcTransport>[];
    final allowRelays = await SettingsRuntime.instance.nodeAllowRelays();

    if (lanHint != null && lanHint.isNotEmpty) {
      transports.add(
        LanPpcTransport(baseUri: parseLanBase(lanHint), signer: _signer),
      );
    }

    if (allowRelays &&
        relayUrl != null &&
        relayUrl.isNotEmpty &&
        storageNodeId != null &&
        storageNodeId.isNotEmpty) {
      transports.add(
        RelayPpcTransport(
          relayUrl: relayUrl,
          storageNodeId: storageNodeId,
          signer: _signer,
        ),
      );
    }

    if (transports.isEmpty) return null;
    if (transports.length == 1) return transports.first;
    return CompositePpcTransport(transports: transports);
  }

  Map<String, dynamic> _decodePairResponse(PpcTransportResponse resp) {
    if (resp.statusCode == 403) {
      throw PpcException(403, 'bad or expired pairing code');
    }
    if (resp.statusCode >= 400) {
      throw PpcException(
        resp.statusCode,
        _errorDetail(resp.body) ?? 'pair failed HTTP ${resp.statusCode}',
      );
    }
    try {
      return jsonDecode(utf8.decode(resp.body)) as Map<String, dynamic>;
    } on FormatException catch (e) {
      throw PpcException(0, 'invalid pair response JSON: $e');
    }
  }

  void _throwOnError(PpcTransportResponse resp, {required Set<int> allowed}) {
    if (allowed.contains(resp.statusCode)) return;
    if (resp.statusCode == 401) {
      throw PpcException(401, _errorDetail(resp.body) ?? 'unauthorized');
    }
    throw PpcException(
      resp.statusCode,
      _errorDetail(resp.body) ?? 'HTTP ${resp.statusCode}',
    );
  }

  String? _errorDetail(List<int> body) {
    if (body.isEmpty) return null;
    try {
      final json = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      return (json['detail'] ?? json['error'])?.toString();
    } catch (_) {
      return utf8.decode(body, allowMalformed: true);
    }
  }
}
