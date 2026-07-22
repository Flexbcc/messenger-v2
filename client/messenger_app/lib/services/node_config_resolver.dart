import '../services/local_settings_store.dart';
import '../services/settings_catalog_bridge.dart';
import '../services/settings_runtime.dart';
import 'bootstrap_service.dart';

/// Resolves effective node URLs from catalog + bootstrap invite.
class NodeConfigResolver {
  NodeConfigResolver({LocalSettingsStore? store}) : _store = store ?? LocalSettingsStore();

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
        return addr.startsWith('http') ? addr : 'https://$addr';
      }
      // Custom enabled but empty address — fall back only when allowed.
      if (!await SettingsRuntime.instance.nodeAllowFallback()) {
        return _defaultHome;
      }
    }
    final primary = BootstrapStore.current?.homeUrl;
    if (primary != null && primary.isNotEmpty) return primary;
    if (await SettingsRuntime.instance.nodeAllowFallback()) {
      return _defaultHome;
    }
    return primary ?? _defaultHome;
  }

  Future<bool> allowServiceNodes() => SettingsRuntime.instance.nodeAllowServiceNodes();

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
    if (await proxyEnabled()) {
      final proxy = await proxyUrl();
      final type = await proxyType();
      parts.add(proxy == null ? 'прокси ($type) не задан' : 'прокси $type → $proxy');
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
