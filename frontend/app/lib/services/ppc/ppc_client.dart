// Direct-mode PPC client — HTTP contract in storage-app/docs/WIRE.md.
//
// Pairing flow (QR payload v2): storage-app/docs/PAIRING-FLOWS.md.

import 'dart:convert';

import '../../crypto/auth_keypair.dart';
import '../account_scope_id.dart';
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
  static const _maxPairResponseBytes = 256 * 1024;
  static const _maxErrorDetailBytes = 8 * 1024;
  static final RegExp _blobKeyPattern = RegExp(r'^[0-9a-f]{64}$');

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
    validatePpcNodeId(nodeId, field: 'client node id');
    final normalizedName = deviceName.trim();
    if (normalizedName.isEmpty ||
        normalizedName.length > 128 ||
        normalizedName.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
      throw ArgumentError.value(
        deviceName,
        'deviceName',
        'invalid device name',
      );
    }
    return PpcClient._(
      authKeyPair: authKeyPair,
      nodeId: nodeId,
      deviceName: normalizedName,
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
        errors.add('LAN: ${_safeRouteError(e.message)}');
      } catch (e) {
        errors.add('LAN: unavailable');
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
          errors.add('mDNS: ${_safeRouteError(e.message)}');
        } catch (e) {
          errors.add('mDNS: unavailable');
        }
      }
    }

    final relay = payload.reach.relay;
    if (pairResponse == null && relay != null && relay.isComplete) {
      errors.add('relay: authenticated client relay is not available');
    }

    if (pairResponse == null || routeKind == null) {
      throw PpcException(
        0,
        errors.isEmpty ? 'no route to storage-app' : errors.join('; '),
      );
    }

    final storagePubkey = validatePpcStoragePubkey(
      pairResponse['storage_pubkey'],
    );
    if (storagePubkey != payload.storagePubkey) {
      throw PpcException(0, 'storage identity does not match pairing code');
    }

    _storagePubkey = storagePubkey;
    _transport = _buildTransport(lanHint: lanHint);
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
    final path = _blobPath(userId, key);
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
    final path = _blobPath(userId, key);
    final resp = await transport.request(method: 'GET', path: path);
    if (resp.statusCode == 404) return null;
    _throwOnError(resp, allowed: {200});
    return resp.body;
  }

  /// DELETE blob (idempotent — 404 treated as success).
  Future<void> delete({required String userId, required String key}) async {
    final transport = _requireTransport();
    final path = _blobPath(userId, key);
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

  Future<PpcTransport?> _transportFromVault(PpcVaultState state) async {
    return _buildTransport(lanHint: state.lanHint);
  }

  PpcTransport? _buildTransport({String? lanHint}) {
    final transports = <PpcTransport>[];
    if (lanHint != null && lanHint.isNotEmpty) {
      transports.add(
        LanPpcTransport(baseUri: parseLanBase(lanHint), signer: _signer),
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
    if (resp.body.length > _maxPairResponseBytes) {
      throw PpcException(0, 'pair response is too large');
    }
    try {
      final decoded = jsonDecode(utf8.decode(resp.body));
      if (decoded is! Map<String, dynamic> ||
          decoded.length != 1 ||
          !decoded.containsKey('storage_pubkey')) {
        throw const FormatException('unexpected pair response shape');
      }
      return decoded;
    } on FormatException {
      throw PpcException(0, 'invalid pair response');
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
    final bounded = body.length <= _maxErrorDetailBytes
        ? body
        : body.sublist(0, _maxErrorDetailBytes);
    try {
      final decoded = jsonDecode(utf8.decode(bounded));
      if (decoded is! Map<String, dynamic>) return null;
      final detail = decoded['detail'] ?? decoded['error'];
      return detail is String ? _sanitizeDetail(detail) : null;
    } catch (_) {
      return null;
    }
  }

  static String _blobPath(String userId, String key) {
    final validatedUserId = AccountScopeId.require(userId);
    if (!_blobKeyPattern.hasMatch(key)) {
      throw ArgumentError.value(key, 'key', 'expected lowercase SHA-256 hex');
    }
    return '/ppc/blob/${Uri.encodeComponent(validatedUserId)}/$key';
  }

  static String _safeRouteError(String message) {
    const allowed = {
      'bad or expired pairing code',
      'invalid pair response',
      'pair response is too large',
    };
    return allowed.contains(message) ? message : 'unavailable';
  }

  static String? _sanitizeDetail(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > 256) return null;
    if (trimmed.runes.any((rune) => rune < 0x20 && rune != 0x09)) {
      return null;
    }
    return trimmed;
  }
}
