/// Result of probing one infrastructure endpoint (/health).
class ConnectionProbeResult {
  const ConnectionProbeResult({
    required this.id,
    required this.label,
    required this.url,
    this.reachable = false,
    this.latencyMs,
    this.nodeRole,
    this.error,
    this.clientDirect = true,
  });

  final String id;
  final String label;
  final String url;
  final bool reachable;
  final int? latencyMs;
  final String? nodeRole;
  final String? error;
  /// False for federation-only nodes (Relay) — not probed via /health from client.
  final bool clientDirect;

  String get statusLabel {
    if (reachable) {
      final ms = latencyMs;
      return ms == null ? 'Доступен' : '$ms мс';
    }
    return error ?? 'Недоступен';
  }
}

/// Snapshot for the connection status screen.
class ConnectionStatusSnapshot {
  const ConnectionStatusSnapshot({
    required this.probedAt,
    required this.endpoints,
    required this.websocketConnected,
    this.lastConversationSyncAt,
  });

  final DateTime probedAt;
  final List<ConnectionProbeResult> endpoints;
  final bool websocketConnected;
  final DateTime? lastConversationSyncAt;

  /// Endpoints the Flutter client talks to directly (Gateway, Home, …).
  bool get clientReachable =>
      endpoints.where((e) => e.clientDirect).every((e) => e.reachable);

  bool get allReachable => endpoints.every((e) => e.reachable);
}
