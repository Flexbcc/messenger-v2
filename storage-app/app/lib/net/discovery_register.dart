// Регистрация storage-app в discovery (SPEC §7, capability personal_pc).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../pairing/payload.dart';

/// Минимальная регистрация + heartbeat в discovery control plane.
class PpcDiscoveryRegister {
  static const _heartbeatInterval = Duration(seconds: 60);

  final String discoveryUrl;
  final String nodeId;
  final String nodeUrl;
  final String softwareVersion;

  Timer? _heartbeat;
  bool _running = false;

  PpcDiscoveryRegister({
    required this.discoveryUrl,
    required this.nodeId,
    required this.nodeUrl,
    this.softwareVersion = '0.0.1',
  });

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _register();
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) => _heartbeatOnce());
  }

  Future<void> stop() async {
    _running = false;
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  Future<void> _register() async {
    await _post(
      '${discoveryUrl.replaceAll(RegExp(r'/+$'), '')}/registry/nodes',
      {
        'node_id': nodeId,
        'node_url': nodeUrl,
        'capabilities': ['personal_pc'],
        'software_version': softwareVersion,
        'cluster_id': 'default',
      },
    );
  }

  Future<void> _heartbeatOnce() async {
    if (!_running) return;
    await _post(
      '${discoveryUrl.replaceAll(RegExp(r'/+$'), '')}/registry/nodes/$nodeId/heartbeat',
      {'software_version': softwareVersion},
    );
  }

  Future<void> _post(String url, Map<String, Object?> body) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse(url));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final resp = await req.close();
      await resp.drain<void>();
      if (resp.statusCode >= 400) {
        stderr.writeln('discovery $url → HTTP ${resp.statusCode}');
      }
    } catch (e) {
      stderr.writeln('discovery $url failed: $e');
    } finally {
      client.close(force: true);
    }
  }
}

/// Конфиг relay/discovery из env (PPC_*).
class PpcRelayEnvConfig {
  final String relayUrl;
  final String discoveryUrl;
  final String storageNodeId;

  const PpcRelayEnvConfig({
    required this.relayUrl,
    required this.discoveryUrl,
    required this.storageNodeId,
  });

  bool get isComplete =>
      relayUrl.isNotEmpty &&
      discoveryUrl.isNotEmpty &&
      storageNodeId.isNotEmpty;

  PpcRelayReach? get relayReach => isComplete
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
    );
  }
}
