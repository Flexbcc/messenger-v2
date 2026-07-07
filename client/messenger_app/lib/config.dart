/// MVP config: single Home Node + Media Node this client talks to.
/// A real multi-node deployment would resolve these per-conversation via
/// Discovery Node (see spec/0604_DISCOVERY_NODE.md) rather than hardcoding.
class AppConfig {
  static const String homeNodeUrl = String.fromEnvironment(
    'HOME_NODE_URL',
    defaultValue: 'http://localhost:8001',
  );
  static const String mediaNodeUrl = String.fromEnvironment(
    'MEDIA_NODE_URL',
    defaultValue: 'http://localhost:8004',
  );

  // Resolves Turn Node addresses (spec/0605_TURN_NODE.md) — a real
  // multi-node deployment would let clients discover this from wherever
  // they already are, same caveat as above.
  static const String discoveryNodeUrl = String.fromEnvironment(
    'DISCOVERY_NODE_URL',
    defaultValue: 'http://localhost:8003',
  );

  static const String gatewayNodeUrl = String.fromEnvironment(
    'GATEWAY_NODE_URL',
    defaultValue: 'http://localhost:8007',
  );

  /// Legacy compile-time constant — clients do not call Relay directly (see
  /// project/docs/architecture-network.md). Federation uses Relay server-to-server.
  static const String relayNodeUrl = String.fromEnvironment(
    'RELAY_NODE_URL',
    defaultValue: 'http://localhost:8005',
  );

  static String get wsUrl =>
      '${homeNodeUrl.replaceFirst('http', 'ws')}/ws';
}

/// App version shown on «О приложении» — keep in sync with pubspec.yaml.
class AppInfo {
  static const version = '1.0.0';
  static const buildNumber = '1';
}
