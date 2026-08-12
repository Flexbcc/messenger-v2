import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/connection_probe_result.dart';

/// Probes node /health endpoints and measures round-trip latency.
class ConnectionStatusService {
  const ConnectionStatusService();

  static const _timeout = Duration(seconds: 4);

  Future<ConnectionProbeResult> probeEndpoint({
    required String id,
    required String label,
    required String baseUrl,
  }) async {
    final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/health');
    final started = DateTime.now();
    try {
      final resp = await http.get(uri).timeout(_timeout);
      final latency = DateTime.now().difference(started).inMilliseconds;
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return ConnectionProbeResult(
          id: id,
          label: label,
          url: baseUrl,
          latencyMs: latency,
          error: 'HTTP ${resp.statusCode}',
        );
      }
      String? role;
      try {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        role = body['node_role'] as String?;
      } catch (_) {}
      return ConnectionProbeResult(
        id: id,
        label: label,
        url: baseUrl,
        reachable: true,
        latencyMs: latency,
        nodeRole: role,
      );
    } catch (e) {
      return ConnectionProbeResult(
        id: id,
        label: label,
        url: baseUrl,
        error: _friendlyError(e),
      );
    }
  }

  /// Relay is internal (Home → Relay → Home). Clients only see it via Discovery registry.
  Future<ConnectionProbeResult> probeRelayViaDiscovery() async {
    const label = 'Relay (federation)';
    const urlNote = 'внутренний узел · статус через Discovery';
    final started = DateTime.now();
    try {
      final uri = Uri.parse(AppConfig.discoveryNodeUrl).replace(
        path: '/registry/nodes',
        queryParameters: {'capability': 'relay'},
      );
      final resp = await http.get(uri).timeout(_timeout);
      final latency = DateTime.now().difference(started).inMilliseconds;
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return ConnectionProbeResult(
          id: 'relay',
          label: label,
          url: urlNote,
          clientDirect: false,
          latencyMs: latency,
          error: 'Discovery HTTP ${resp.statusCode}',
        );
      }
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final nodes = (body['nodes'] as List<dynamic>? ?? [])
          .map((n) => n as Map<String, dynamic>)
          .toList();
      final online = nodes.where((n) => n['status'] == 'online').toList();
      if (online.isEmpty) {
        return ConnectionProbeResult(
          id: 'relay',
          label: label,
          url: urlNote,
          clientDirect: false,
          latencyMs: latency,
          error: nodes.isEmpty
              ? 'Не зарегистрирован в Discovery'
              : 'Offline в Discovery',
        );
      }
      final first = online.first;
      final nodeId = first['node_id'] as String? ?? 'relay';
      return ConnectionProbeResult(
        id: 'relay',
        label: label,
        url: '$urlNote · $nodeId',
        clientDirect: false,
        reachable: true,
        latencyMs: latency,
        nodeRole: 'relay',
      );
    } catch (e) {
      return ConnectionProbeResult(
        id: 'relay',
        label: label,
        url: urlNote,
        clientDirect: false,
        error: _friendlyError(e),
      );
    }
  }

  Future<ConnectionStatusSnapshot> probeAll({
    required bool websocketConnected,
    DateTime? lastConversationSyncAt,
  }) async {
    final endpoints = await Future.wait([
      probeEndpoint(
        id: 'gateway',
        label: 'Gateway',
        baseUrl: AppConfig.gatewayNodeUrl,
      ),
      probeEndpoint(
        id: 'home',
        label: 'Home Node',
        baseUrl: AppConfig.homeNodeUrl,
      ),
      probeEndpoint(
        id: 'discovery',
        label: 'Discovery',
        baseUrl: AppConfig.discoveryNodeUrl,
      ),
      probeEndpoint(
        id: 'media',
        label: 'Media',
        baseUrl: AppConfig.mediaNodeUrl,
      ),
      probeRelayViaDiscovery(),
    ]);
    return ConnectionStatusSnapshot(
      probedAt: DateTime.now(),
      endpoints: endpoints,
      websocketConnected: websocketConnected,
      lastConversationSyncAt: lastConversationSyncAt,
    );
  }

  String _friendlyError(Object e) {
    final text = e.toString();
    if (text.contains('SocketException') ||
        text.contains('Connection refused')) {
      return 'Сервер не отвечает';
    }
    if (text.contains('TimeoutException')) return 'Таймаут';
    return 'Ошибка соединения';
  }
}
