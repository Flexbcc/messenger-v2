import 'bootstrap_service.dart';

/// MVP config: compile-time defaults, overridden by [BootstrapStore] after invite.
class AppConfig {
  static const String _defaultHome = String.fromEnvironment(
    'HOME_NODE_URL',
    defaultValue: 'http://localhost:8001',
  );
  static const String _defaultMedia = String.fromEnvironment(
    'MEDIA_NODE_URL',
    defaultValue: 'http://localhost:8004',
  );
  static const String _defaultDiscovery = String.fromEnvironment(
    'DISCOVERY_NODE_URL',
    defaultValue: 'http://localhost:8003',
  );
  static const String _defaultGateway = String.fromEnvironment(
    'GATEWAY_NODE_URL',
    defaultValue: 'http://localhost:8007',
  );

  static String get homeNodeUrl => BootstrapStore.current?.homeUrl ?? _defaultHome;
  static String get mediaNodeUrl => BootstrapStore.current?.mediaUrl ?? _defaultMedia;
  static String get discoveryNodeUrl =>
      BootstrapStore.current?.discoveryUrl ?? _defaultDiscovery;
  static String get gatewayNodeUrl =>
      BootstrapStore.current?.gatewayUrl ?? _defaultGateway;
  static String get clusterId => BootstrapStore.current?.clusterId ?? 'default';

  static String get wsUrl => '${homeNodeUrl.replaceFirst('http', 'ws')}/ws';

  /// Legacy compile-time constant — clients do not call Relay directly.
  static const String relayNodeUrl = String.fromEnvironment(
    'RELAY_NODE_URL',
    defaultValue: 'http://localhost:8005',
  );
}

class AppInfo {
  static const version = '1.0.0';
  static const buildNumber = '1';
}
