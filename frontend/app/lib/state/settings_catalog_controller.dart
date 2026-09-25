import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/settings_catalog.dart';
import '../models/settings_impl_status.dart';
import '../services/catalog_sync.dart';
import '../services/catalog_seed_service.dart';
import '../services/debug_log.dart';
import '../services/settings_catalog_bridge.dart';
import '../services/account_settings_scope.dart';
import '../config.dart';
import '../services/local_settings_store.dart';
import '../services/media_cache.dart';
import '../state/app_controller.dart';
import '../state/notification_settings.dart';
import '../state/theme_settings.dart';
import '../screens/private_mode/private_mode_state.dart';

/// Loads the shared settings catalog asset once.
final settingsCatalogProvider = FutureProvider<SettingsCatalog>((ref) async {
  final raw = await rootBundle.loadString(
    'assets/settings/ouo-settings-spec.json',
  );
  final json = jsonDecode(raw) as Map<String, dynamic>;
  final catalog = SettingsCatalog.fromJson(json);
  final unavailableIds = <String>{...SettingsImplStatus.retiredIds};
  for (final section in catalog.sections) {
    for (final setting in section.settings) {
      if (!SettingsRuntimeWiring.covers(setting.id)) {
        unavailableIds.add(setting.id);
      }
    }
  }
  return catalog.withoutSettings(unavailableIds);
});

/// Holds live values for catalog-driven settings, persisted locally by setting
/// id (`catalog.<id>`). Syncs to legacy runtime stores via [SettingsCatalogBridge].
final settingsCatalogValuesProvider =
    ChangeNotifierProvider<SettingsCatalogValues>(
      (ref) => SettingsCatalogValues(read: ref.read),
    );

class SettingsCatalogValues extends ChangeNotifier {
  SettingsCatalogValues({
    LocalSettingsStore? store,
    SettingsCatalogBridge? bridge,
    required T Function<T>(ProviderListenable<T> provider) read,
  }) : _store = store ?? LocalSettingsStore(),
       _bridge = bridge ?? SettingsCatalogBridge(),
       _providerRead = read {
    AccountSettingsScope.addListener((_) async {
      final SettingsCatalog catalog =
          _catalog ?? await _providerRead(settingsCatalogProvider.future);
      await load(catalog, force: true);
      await _refreshLegacyNotifiers();
      try {
        await _providerRead(privateModeStateProvider).load();
      } catch (error) {
        DebugLog.instance.error(
          'settings',
          'Private mode reload after account switch failed',
          error,
        );
      }
    });
  }

  final LocalSettingsStore _store;
  final SettingsCatalogBridge _bridge;
  final T Function<T>(ProviderListenable<T> provider) _providerRead;
  final Map<String, Object?> _values = {};
  SettingsCatalog? _catalog;
  bool _loaded = false;
  bool _loading = false;

  bool get loaded => _loaded;

  static String _key(String id) => SettingsCatalogBridge.catalogKey(id);

  Object? valueOf(SettingDef def) {
    if (_values.containsKey(def.id)) return _values[def.id];
    return def.defaultValue;
  }

  Object? valueById(String id) {
    if (_values.containsKey(id)) return _values[id];
    return _catalog?.settingById(id)?.defaultValue;
  }

  /// Loads catalog values. Legacy screens win for mapped settings — we mirror
  /// them into catalog keys, not the other way around on load.
  Future<void> load(SettingsCatalog catalog, {bool force = false}) async {
    if ((_loaded && !force) || _loading) return;
    _loading = true;
    _catalog = catalog;
    await CatalogSync.syncAllFromLegacy();
    await _reloadValues(catalog);
    _loaded = true;
    _loading = false;
    notifyListeners();
  }

  /// Refresh in-memory values from storage (after legacy screen edits).
  Future<void> reloadFromLegacy(SettingsCatalog catalog) async {
    _catalog = catalog;
    await CatalogSync.syncAllFromLegacy();
    await _reloadValues(catalog);
    notifyListeners();
  }

  Future<void> _reloadValues(SettingsCatalog catalog) async {
    _values.clear();
    for (final section in catalog.sections) {
      for (final def in section.settings) {
        if (!def.isPersistable || def.isSecret) continue;
        _values[def.id] = await _loadValue(def);
      }
    }
  }

  Future<void> _refreshLegacyNotifiers() async {
    await _bridge.refreshLegacyNotifiers(
      theme: _providerRead(themeSettingsProvider),
      notifications: _providerRead(notificationSettingsProvider),
    );
  }

  Future<Object?> _loadValue(SettingDef def) async {
    final key = _key(def.id);
    try {
      // Missing optional/profile values are not corrupted values. Their
      // catalog fallback may intentionally be empty until onboarding or the
      // server profile supplies the first value, so do not validate/remove a
      // key that has never existed.
      if (!await _store.containsKey(key)) {
        return _defaultValue(def);
      }
      late final Object? value;
      switch (def.type) {
        case 'boolean':
          value = await _store.getBool(key, def.defaultValue == true);
          break;
        case 'number':
          value = await _store.getInt(
            key,
            (def.defaultValue as num?)?.toInt() ?? 0,
          );
          break;
        case 'multi_select':
          final saved = await _store.getStringList(key);
          value = saved.isNotEmpty ? saved : _defaultValue(def);
          break;
        case 'single_select':
        case 'text':
          value = await _store.getString(
            key,
            def.defaultValue?.toString() ?? '',
          );
          break;
        default:
          return await _store.getString(
            key,
            def.defaultValue?.toString() ?? '',
          );
      }
      def.validateValue(value);
      return value;
    } catch (error) {
      if (error is! FormatException && error is! TypeError) rethrow;
      DebugLog.instance.warn(
        'settings',
        'discarding invalid stored value for ${def.id}: $error',
      );
      await _store.remove(key);
      return _defaultValue(def);
    }
  }

  Object? _defaultValue(SettingDef def) {
    if (def.type == 'multi_select') {
      return (def.defaultValue as List? ?? const [])
          .map((value) => value.toString())
          .toList(growable: false);
    }
    if (def.type == 'boolean') return def.defaultValue == true;
    if (def.type == 'number') {
      return (def.defaultValue as num?)?.toInt() ?? 0;
    }
    return def.defaultValue?.toString() ?? '';
  }

  Future<void> setValue(SettingDef def, Object? value) async {
    if (def.isSecret) {
      throw StateError('Secret catalog values must use SecureCatalogSecrets');
    }
    if (!def.isPersistable) {
      throw StateError('Setting ${def.id} is not persistable');
    }
    def.validateValue(value);
    final key = _key(def.id);
    switch (def.type) {
      case 'boolean':
        await _store.setBool(key, value == true);
        break;
      case 'number':
        await _store.setInt(key, (value as num?)?.toInt() ?? 0);
        break;
      case 'multi_select':
        await _store.setStringList(
          key,
          (value as List?)?.map((e) => e.toString()).toList() ?? const [],
        );
        break;
      default:
        await _store.setString(key, value?.toString() ?? '');
    }
    _values[def.id] = value;
    notifyListeners();
    await _bridge.onCatalogChanged(def, value);
    if (def.id == 'messages.auto_delete_enabled' ||
        def.id == 'messages.auto_delete_ttl') {
      await _providerRead(appControllerProvider).loadSecretChatPreferences();
    }
    if (def.id == 'media.cache_limit_gb' ||
        def.id == 'media.auto_cleanup' ||
        def.id == 'media.auto_cleanup_after') {
      await MediaCache.instance.enforceLimits();
    }
    if (def.id.startsWith('node.')) {
      await AppConfig.refreshFromCatalog();
    }
    if (def.id.startsWith('privacy.')) {
      await _providerRead(appControllerProvider).refreshPrivacyRuntime();
    }
    if (def.id.startsWith('hidden.')) {
      await _providerRead(appControllerProvider).refreshHiddenChatsPolicies();
    }
    // Product boundary: Home Node routes traffic; preferences are stored and
    // enforced by this client. Never send catalog settings, PINs, notification
    // preferences, or other device behavior to the routing server.
    await _refreshLegacyNotifiers();
  }

  bool isVisible(SettingDef def) {
    final rule = def.visibleIf;
    if (rule == null) return true;
    final dep = _catalog?.settingById(rule.setting);
    if (dep != null) {
      return rule.isSatisfiedBy(valueOf(dep));
    }
    return rule.isSatisfiedBy(valueById(rule.setting));
  }
}

/// Initializes catalog mirror from legacy screens at app boot.
Future<void> bootstrapSettingsCatalog(
  T Function<T>(ProviderListenable<T> provider) read,
) async {
  await CatalogSync.syncAllFromLegacy();
  // A fresh install has no network yet. Do not turn the intentional HTTPS
  // fail-closed rule into a noisy boot error while onboarding is on screen.
  // Once an invite is redeemed (or a safe compile-time Home is supplied),
  // normal resolution and validation run unchanged.
  if (AppConfig.hasUsableInitialHome) {
    await AppConfig.refreshFromCatalog();
  }
  final catalog = await read(settingsCatalogProvider.future);
  await CatalogSeedService().maybeAutoSeed(catalog);
  await read(settingsCatalogValuesProvider).load(catalog);
}
