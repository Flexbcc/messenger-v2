import 'package:http/http.dart' as http;

import '../services/local_settings_store.dart';
import '../services/settings_catalog_bridge.dart';
import '../services/settings_runtime.dart';
import 'bootstrap_service.dart';

/// Resolves effective node URLs from catalog + bootstrap invite.
class NodeConfigResolver {
  NodeConfigResolver({LocalSettingsStore? store})
    : _store = store ?? LocalSettingsStore();

  final LocalSettingsStore _store;

  static const _defaultHome = String.fromEnvironment(
    'HOME_NODE_URL',
    defaultValue: 'http://localhost:8001',
  );

  Future<String> homeNodeUrl() async {
    final customEnabled = await _store.getBool(
      SettingsCatalogBridge.catalogKey('node.custom_enabled'),
      false,
    );
    if (customEnabled) {
      final addr = await _store.getString(
        SettingsCatalogBridge.catalogKey('node.custom_address'),
        '',
      );
      if (addr.isNotEmpty) {
        return validatedNetworkOrigin(
          addr.startsWith('http') ? addr : 'https://$addr',
          'custom Home address',
        );
      }
      // Custom mode without an address must not silently select another node.
      if (!await SettingsRuntime.instance.nodeAllowFallback()) {
        throw StateError('Custom Home address is required');
      }
    }
    final primary = BootstrapStore.current?.homeUrl;
    if (primary != null && primary.isNotEmpty) return primary;
    if (await SettingsRuntime.instance.nodeAllowFallback()) {
      return validatedNetworkOrigin(_defaultHome, 'default Home address');
    }
    throw StateError('Home Node is not configured and fallback is disabled');
  }

  /// Backup Home candidates persisted from the last `/gateway/routing`
  /// response (Post-R5 phase C lite, docs/reality/R4-routing.md). Empty when
  /// bootstrapped without a Gateway (compile-time default only) or when no
  /// alternate Home nodes were advertised.
  List<String> backupHomeUrls() =>
      BootstrapStore.current?.backupHomeUrls ?? const [];

  String? discoveryUrl() => BootstrapStore.current?.discoveryUrl;

  List<String> discoveryUrls() =>
      BootstrapStore.current?.discoveryUrls ?? const [];

  String? gatewayUrl() => BootstrapStore.current?.gatewayUrl;

  /// On connection failure, probe the primary Home then each backup in
  /// order and return the first one that answers `/health`. Used both for
  /// diagnostics/status UI and as the candidate lookup for
  /// [failoverToBackupHome] below.
  Future<String?> firstReachableHomeUrl({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final primary = await homeNodeUrl();
    final candidates = {primary, ...backupHomeUrls()};
    for (final url in candidates) {
      if (url.isEmpty) continue;
      if (await _probeHealth(url, timeout: timeout)) return url;
    }
    return null;
  }

  /// Probes only the current primary Home's `/health` — cheap check callers
  /// use to decide whether a failover attempt (or a `/health` sweep of every
  /// backup via [firstReachableHomeUrl]) is even warranted.
  Future<bool> isPrimaryReachable({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final primary = await homeNodeUrl();
    if (primary.isEmpty) return false;
    return _probeHealth(primary, timeout: timeout);
  }

  Future<bool> _probeHealth(
    String rawOrigin, {
    required Duration timeout,
  }) async {
    final client = http.Client();
    try {
      final origin = validatedNetworkOrigin(rawOrigin, 'Home health origin');
      final request =
          http.Request(
              'GET',
              Uri.parse('${origin.replaceAll(RegExp(r'/+$'), '')}/health'),
            )
            ..followRedirects = false
            ..maxRedirects = 0;
      final response = await client.send(request).timeout(timeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// Post-R5 full failover (docs/reality/R4-routing.md Gaps — "Нет client
  /// backup routes"): if [firstReachableHomeUrl] finds a *different* Home
  /// than the current persisted primary, actually switch to it — persist it
  /// as the new [NetworkBootstrap.homeUrl] in [BootstrapStore] and move the
  /// old primary into [NetworkBootstrap.backupHomeUrls] (so it's retried
  /// first if this backup also goes down later).
  ///
  /// Does **not** touch [AppConfig]'s resolved cache or re-authenticate —
  /// callers (see `AppController._maybeFailoverHome`) own that, since they
  /// also decide what to do about the current session on the new Home.
  ///
  /// Returns the new primary URL when a swap happened, or `null` when there
  /// was nothing to do (already on the best reachable candidate, or nothing
  /// answered at all).
  Future<String?> failoverToBackupHome({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final bootstrap = BootstrapStore.current;
    if (bootstrap == null || bootstrap.backupHomeUrls.isEmpty) return null;
    final reachable = await firstReachableHomeUrl(timeout: timeout);
    if (reachable == null || reachable == bootstrap.homeUrl) return null;
    final remainingBackups = bootstrap.backupHomeUrls
        .where((u) => u != reachable)
        .toList();
    await BootstrapStore.save(
      bootstrap.copyWith(
        homeUrl: reachable,
        backupHomeUrls: [bootstrap.homeUrl, ...remainingBackups],
      ),
    );
    return reachable;
  }

  Future<bool> allowServiceNodes() =>
      SettingsRuntime.instance.nodeAllowServiceNodes();

  Future<bool> allowFallback() => SettingsRuntime.instance.nodeAllowFallback();

  Future<String> certificateFingerprint() =>
      SettingsRuntime.instance.nodeCertificateFingerprint();

  Future<bool> allowMobileData() => _store.getBool(
    SettingsCatalogBridge.catalogKey('node.mobile_data'),
    true,
  );

  Future<bool> allowRelays() => SettingsRuntime.instance.nodeAllowRelays();

  Future<bool> proxyEnabled() => SettingsRuntime.instance.nodeProxyEnabled();

  Future<String> proxyType() => SettingsRuntime.instance.nodeProxyType();

  Future<String?> proxyUrl() => SettingsRuntime.instance.nodeProxyUrl();

  /// Human-readable connection summary for status UI.
  Future<String> connectionSummary() async {
    final home = await homeNodeUrl();
    final parts = <String>[home];
    final backups = backupHomeUrls();
    if (backups.isNotEmpty) {
      parts.add('backup homes: ${backups.length}');
    }
    if (await proxyEnabled()) {
      final proxy = await proxyUrl();
      final type = await proxyType();
      parts.add(
        proxy == null ? 'прокси ($type) не задан' : 'прокси $type → $proxy',
      );
    }
    if (!await allowRelays()) {
      parts.add('релеи выкл.');
    }
    if (!await allowServiceNodes()) {
      parts.add('service nodes выкл.');
    }
    if (!await allowFallback()) {
      parts.add('fallback выкл.');
    }
    final fp = await certificateFingerprint();
    if (fp != '—') parts.add('fp=$fp');
    return parts.join(' · ');
  }
}
