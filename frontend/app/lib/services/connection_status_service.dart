import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/connection_probe_result.dart';

/// Probes node /health endpoints and measures round-trip latency.
class ConnectionStatusService {
  const ConnectionStatusService();

  static const _timeout = Duration(seconds: 4);
  static const _maxHealthBytes = 64 * 1024;
  static const _maxRegistryBytes = 2 * 1024 * 1024;

  Future<({int statusCode, Object? body})> _getJson(
    Uri uri, {
    required int maxBytes,
  }) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..maxRedirects = 0;
      final response = await client.send(request).timeout(_timeout);
      final declared = response.contentLength;
      if (declared != null && (declared < 0 || declared > maxBytes)) {
        throw const FormatException('response is too large');
      }
      final bytes = BytesBuilder(copy: false);
      var received = 0;
      await for (final chunk in response.stream.timeout(_timeout)) {
        received += chunk.length;
        if (received > maxBytes) {
          throw const FormatException('response is too large');
        }
        bytes.add(chunk);
      }
      final raw = bytes.takeBytes();
      return (
        statusCode: response.statusCode,
        body: raw.isEmpty ? null : jsonDecode(utf8.decode(raw)),
      );
    } finally {
      client.close();
    }
  }

  Future<ConnectionProbeResult> probeEndpoint({
    required String id,
    required String label,
    required String baseUrl,
  }) async {
    final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/health');
    final started = DateTime.now();
    try {
      final resp = await _getJson(uri, maxBytes: _maxHealthBytes);
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
        final body = resp.body as Map<String, dynamic>;
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
    Object? lastError;
    for (final discoveryUrl in AppConfig.discoveryNodeUrls) {
      final started = DateTime.now();
      try {
        final uri = Uri.parse(discoveryUrl).replace(
          path: '/registry/nodes',
          queryParameters: {'capability': 'relay'},
        );
        final resp = await _getJson(uri, maxBytes: _maxRegistryBytes);
        final latency = DateTime.now().difference(started).inMilliseconds;
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          lastError = 'Discovery HTTP ${resp.statusCode}';
          continue;
        }
        final body = resp.body;
        if (body is! Map<String, dynamic>) {
          throw const FormatException('invalid Discovery response');
        }
        final rawNodes = body['nodes'];
        if (rawNodes is! List || rawNodes.length > 10000) {
          throw const FormatException('invalid Discovery node list');
        }
        final nodes = rawNodes.whereType<Map<String, dynamic>>().toList();
        final online = nodes.where((n) => n['status'] == 'online').toList();
        if (online.isEmpty) {
          lastError = nodes.isEmpty
              ? 'Не зарегистрирован в Discovery'
              : 'Offline в Discovery';
          continue;
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
        lastError = e;
      }
    }
    return ConnectionProbeResult(
      id: 'relay',
      label: label,
      url: urlNote,
      clientDirect: false,
      error: lastError is String
          ? lastError
          : _friendlyError(lastError ?? 'Discovery unavailable'),
    );
  }

  Future<ConnectionStatusSnapshot> probeAll({
    required bool websocketConnected,
    DateTime? lastConversationSyncAt,
  }) async {
    final discoveryProbes = AppConfig.discoveryNodeUrls.indexed.map((entry) {
      final (index, url) = entry;
      return probeEndpoint(
        id: 'discovery-${index + 1}',
        label: 'Discovery D${index + 1}',
        baseUrl: url,
      );
    });
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
      ...discoveryProbes,
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
