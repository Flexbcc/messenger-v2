import 'services/bootstrap_service.dart';
import 'services/node_config_resolver.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// MVP config: compile-time defaults, overridden by [BootstrapStore] after invite
/// and catalog `node.*` settings.
class AppConfig {
  /// Migration-only password authentication. Production clients use the
  /// device-held Ed25519 key or approval from an already trusted device.
  static const bool allowPasswordAuthBridge = bool.fromEnvironment(
    'ALLOW_PASSWORD_AUTH_BRIDGE',
    defaultValue: false,
  );

  /// Temporary migration escape hatch for pre-device-envelope accounts.
  /// Production builds must remain fail-closed (the default).
  static const bool allowLegacyAccountWideE2ee = bool.fromEnvironment(
    'ALLOW_LEGACY_ACCOUNT_WIDE_E2EE',
    defaultValue: false,
  );

  static const String _callStunUrlsRaw = String.fromEnvironment(
    'CALL_STUN_URLS',
    defaultValue: '',
  );

  static List<String> get callStunUrls => _callStunUrlsRaw
      .split(',')
      .map((value) => value.trim())
      .where((value) => value.startsWith('stun:'))
      .toList(growable: false);

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

  /// Whether startup can safely resolve a Home before onboarding has stored
  /// a bootstrap record. Development defaults intentionally remain HTTP, but
  /// fail closed unless the build explicitly enables insecure local origins.
  static bool get hasUsableInitialHome {
    if (BootstrapStore.current != null) return true;
    try {
      validatedNetworkOrigin(_defaultHome, 'default Home address');
      return true;
    } on FormatException {
      return false;
    }
  }

  static String get homeNodeUrl => validatedNetworkOrigin(
    _resolvedHome.isNotEmpty
        ? _resolvedHome
        : (BootstrapStore.current?.homeUrl ?? _defaultHome),
    'Home Node URL',
  );

  static String get mediaNodeUrl => validatedNetworkOrigin(
    BootstrapStore.current?.mediaUrl ?? _defaultMedia,
    'Media Node URL',
  );
  static String get discoveryNodeUrl => validatedNetworkOrigin(
    BootstrapStore.current?.discoveryUrl ?? _defaultDiscovery,
    'Discovery Node URL',
  );
  static List<String> get discoveryNodeUrls {
    final configured = BootstrapStore.current?.discoveryUrls ?? const [];
    if (configured.isEmpty) return <String>[discoveryNodeUrl];
    return configured
        .map((value) => validatedNetworkOrigin(value, 'Discovery Node URL'))
        .toSet()
        .toList();
  }

  static String get gatewayNodeUrl => validatedNetworkOrigin(
    BootstrapStore.current?.gatewayUrl ?? _defaultGateway,
    'Gateway Node URL',
  );
  static String get clusterId => BootstrapStore.current?.clusterId ?? 'default';

  static String get wsUrl {
    final home = Uri.parse(homeNodeUrl);
    return home
        .replace(scheme: home.scheme == 'https' ? 'wss' : 'ws', path: '/ws')
        .toString();
  }

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
