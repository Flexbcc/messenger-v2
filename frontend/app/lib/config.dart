import 'services/bootstrap_service.dart';
import 'services/node_config_resolver.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// MVP config: compile-time defaults, overridden by [BootstrapStore] after invite
/// and catalog `node.*` settings.
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

  static String _resolvedHome = '';

  static String get homeNodeUrl => _resolvedHome.isNotEmpty
      ? _resolvedHome
      : (BootstrapStore.current?.homeUrl ?? _defaultHome);

  static String get mediaNodeUrl =>
      BootstrapStore.current?.mediaUrl ?? _defaultMedia;
  static String get discoveryNodeUrl =>
      BootstrapStore.current?.discoveryUrl ?? _defaultDiscovery;
  static String get gatewayNodeUrl =>
      BootstrapStore.current?.gatewayUrl ?? _defaultGateway;
  static String get clusterId => BootstrapStore.current?.clusterId ?? 'default';

  static String get wsUrl => '${homeNodeUrl.replaceFirst('http', 'ws')}/ws';

  static Future<void> refreshFromCatalog() async {
    _resolvedHome = await NodeConfigResolver().homeNodeUrl();
  }

  /// Legacy compile-time constant — clients do not call Relay directly.
  static const String relayNodeUrl = String.fromEnvironment(
    'RELAY_NODE_URL',
    defaultValue: 'http://localhost:8005',
  );
}

class AppInfo {
  /// Populated from pubspec via [init] (package_info_plus).
  static String version = '0.1.0';
  static String buildNumber = '1';
  static const channel = 'beta';

  /// Unique fingerprint baked into every web build. Unlike pubspec version,
  /// this changes on every deployment and lets an installed PWA detect that
  /// its JavaScript bundle is stale without relying on a service worker.
  static const buildId = String.fromEnvironment(
    'APP_BUILD_ID',
    defaultValue: '',
  );

  static String get label => '$version+$buildNumber';
  static String get displayVersion => '$version ($channel)';

  static Future<void> init() async {
    try {
      final info = await PackageInfo.fromPlatform();
      version = info.version;
      buildNumber = info.buildNumber;
    } catch (_) {
      // Tests / early boot — keep defaults above.
    }
  }
}
