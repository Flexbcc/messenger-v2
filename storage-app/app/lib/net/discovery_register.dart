// Регистрация storage-app в discovery (SPEC §7, capability personal_pc).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../pairing/payload.dart';

/// Минимальная регистрация + heartbeat в discovery control plane.
class PpcDiscoveryRegister {
  static const _heartbeatInterval = Duration(seconds: 60);
  static const _minBackoff = Duration(seconds: 10);
  static const _maxBackoff = Duration(minutes: 10);

  final String discoveryUrl;
  final String nodeId;
  final String nodeUrl;
  final String storagePubkey;
  final String nodeToken;
  final String softwareVersion;

  Timer? _heartbeat;
  bool _running = false;
  int _consecutiveFailures = 0;

  PpcDiscoveryRegister({
    required this.discoveryUrl,
    required this.nodeId,
    required this.nodeUrl,
    required this.storagePubkey,
    required this.nodeToken,
    this.softwareVersion = '0.0.1',
  });

  Future<void> start() async {
    if (_running) return;
    _validateConfiguration();
    _running = true;
    try {
      final registration = await _register();
      if (registration == null || registration['trust_status'] != 'trusted') {
        throw StateError('storage node is not trusted by Discovery');
      }
      _scheduleHeartbeat();
    } catch (_) {
      _running = false;
      rethrow;
    }
  }

  Future<void> stop() async {
    _running = false;
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  void _scheduleHeartbeat({Duration? delay}) {
    _heartbeat?.cancel();
    final interval = delay ?? _heartbeatInterval;
    _heartbeat = Timer(interval, () async {
      await _heartbeatOnce();
      if (_running) _scheduleHeartbeat();
    });
  }

  Future<Map<String, dynamic>?> _register() {
    return _post(
      '${discoveryUrl.replaceAll(RegExp(r'/+$'), '')}/registry/nodes',
      {
        'node_id': nodeId,
        'node_url': nodeUrl,
        'capabilities': ['storage'],
        'software_version': softwareVersion,
        'cluster_id': 'default',
        'signing_public_key': storagePubkey.substring(8),
      },
    );
  }

  Future<void> _heartbeatOnce() async {
    if (!_running) return;
    final response = await _post(
      '${discoveryUrl.replaceAll(RegExp(r'/+$'), '')}/registry/nodes/$nodeId/heartbeat',
      {
        'software_version': softwareVersion,
        'signing_public_key': storagePubkey.substring(8),
      },
    );
    if (response != null) {
      _consecutiveFailures = 0;
    } else {
      _consecutiveFailures++;
      // Exponential backoff: 10s, 20s, 40s … capped at 10 min.
      final backoffSec =
          _minBackoff.inSeconds *
          (1 << (_consecutiveFailures - 1).clamp(0, 10));
      final backoff = Duration(
        seconds: backoffSec.clamp(0, _maxBackoff.inSeconds),
      );
      stderr.writeln(
        'discovery heartbeat failed ($_consecutiveFailures), retry in ${backoff.inSeconds}s',
      );
      if (_running) _scheduleHeartbeat(delay: backoff);
      return; // _scheduleHeartbeat already rescheduled above
    }
  }

  /// Returns a bounded JSON object on 2xx, otherwise `null`.
  Future<Map<String, dynamic>?> _post(
    String url,
    Map<String, Object?> body,
  ) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(Uri.parse(url));
      req
        ..followRedirects = false
        ..headers.contentType = ContentType.json
        ..headers.set(HttpHeaders.authorizationHeader, 'Bearer $nodeToken')
        ..write(jsonEncode(body));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final responseBody = <int>[];
      await for (final chunk in resp.timeout(const Duration(seconds: 15))) {
        if (responseBody.length + chunk.length > 1024 * 1024) {
          throw const FormatException('Discovery response is too large');
        }
        responseBody.addAll(chunk);
      }
      if (resp.statusCode >= 400) {
        stderr.writeln('discovery request rejected: HTTP ${resp.statusCode}');
        return null;
      }
      final decoded = jsonDecode(utf8.decode(responseBody));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('invalid Discovery response');
      }
      return decoded;
    } catch (e) {
      stderr.writeln('discovery request failed');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  void _validateConfiguration() {
    final discovery = Uri.tryParse(discoveryUrl);
    final advertised = Uri.tryParse(nodeUrl);
    if (discovery == null || !_isSecureOrigin(discovery)) {
      throw StateError('PPC Discovery URL must be an HTTPS origin');
    }
    if (advertised == null || !_isSecureOrigin(advertised)) {
      throw StateError('PPC advertised node URL must be an HTTPS origin');
    }
    if (!_validNodeId(nodeId) ||
        !_validStoragePubkey(storagePubkey) ||
        nodeToken.length < 32 ||
        nodeToken.length > 4096 ||
        nodeToken.runes.any((rune) => rune <= 0x20 || rune == 0x7f) ||
        softwareVersion.isEmpty ||
        softwareVersion.length > 128) {
      throw StateError('invalid PPC Discovery identity configuration');
    }
  }

  static bool _isSecureOrigin(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      (uri.path.isEmpty || uri.path == '/') &&
      !uri.hasQuery &&
      !uri.hasFragment;

  static bool _validNodeId(String value) =>
      value.isNotEmpty &&
      value.length <= 256 &&
      RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value);

  static bool _validStoragePubkey(String value) {
    if (!value.startsWith('ed25519:') || value.length > 64) return false;
    final encoded = value.substring(8);
    try {
      final decoded = base64Decode(encoded);
      return decoded.length == 32 && base64Encode(decoded) == encoded;
    } catch (_) {
      return false;
    }
  }
}

/// Конфиг relay/discovery из env (PPC_*).
class PpcRelayEnvConfig {
  final String relayUrl;
  final String discoveryUrl;
  final String storageNodeId;
  final String nodeToken;

  const PpcRelayEnvConfig({
    required this.relayUrl,
    required this.discoveryUrl,
    required this.storageNodeId,
    required this.nodeToken,
  });

  bool get isRelayComplete => relayUrl.isNotEmpty && storageNodeId.isNotEmpty;

  bool get isDiscoveryComplete =>
      relayUrl.isNotEmpty &&
      discoveryUrl.isNotEmpty &&
      storageNodeId.isNotEmpty &&
      nodeToken.isNotEmpty;

  PpcRelayReach? get relayReach => isRelayComplete
      ? PpcRelayReach(
          discoveryUrl: discoveryUrl,
          storageNodeId: storageNodeId,
          relayUrl: relayUrl,
        )
      : null;

  static PpcRelayEnvConfig? fromPlatform() {
    final relayUrl = Platform.environment['PPC_RELAY_URL']?.trim() ?? '';
    if (relayUrl.isEmpty) return null;
    return PpcRelayEnvConfig(
      relayUrl: relayUrl,
      discoveryUrl: Platform.environment['PPC_DISCOVERY_URL']?.trim() ?? '',
      storageNodeId: Platform.environment['PPC_STORAGE_NODE_ID']?.trim() ?? '',
      nodeToken: Platform.environment['PPC_DISCOVERY_NODE_TOKEN']?.trim() ?? '',
    );
  }
}
