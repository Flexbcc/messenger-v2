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

  List<ConnectionProbeResult> get discoveryEndpoints => endpoints
      .where((endpoint) => endpoint.id.startsWith('discovery-'))
      .toList(growable: false);

  int get reachableDiscoveryCount =>
      discoveryEndpoints.where((endpoint) => endpoint.reachable).length;

  /// The three-source profile tolerates one failed Discovery. A one-source
  /// development profile still requires its sole source.
  int get requiredDiscoveryCount {
    final count = discoveryEndpoints.length;
    if (count <= 1) return count;
    return 2;
  }

  bool get discoveryQuorumReachable =>
      reachableDiscoveryCount >= requiredDiscoveryCount;

  /// Existing conversations depend on the selected Home and its realtime
  /// channel. Gateway, Media and individual Discovery sources may be degraded
  /// without turning the messenger itself offline.
  bool get clientReachable {
    final home = endpoints.where((endpoint) => endpoint.id == 'home');
    return websocketConnected &&
        home.isNotEmpty &&
        home.every((endpoint) => endpoint.reachable);
  }

  bool get allClientServicesReachable => endpoints
      .where((endpoint) => endpoint.clientDirect)
      .every((endpoint) => endpoint.reachable);

  bool get allReachable => endpoints.every((e) => e.reachable);
}
