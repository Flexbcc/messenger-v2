import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/settings_catalog.dart';
import '../services/catalog_sync.dart';
import '../services/catalog_seed_service.dart';
import '../services/profile_settings_sync.dart';
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
  final raw = await rootBundle.loadString('assets/settings/ouo-settings-spec.json');
  final json = jsonDecode(raw) as Map<String, dynamic>;
  return SettingsCatalog.fromJson(json);
});

/// Holds live values for catalog-driven settings, persisted locally by setting
/// id (`catalog.<id>`). Syncs to legacy runtime stores via [SettingsCatalogBridge].
final settingsCatalogValuesProvider =
    ChangeNotifierProvider<SettingsCatalogValues>((ref) => SettingsCatalogValues(read: ref.read));

class SettingsCatalogValues extends ChangeNotifier {
  SettingsCatalogValues({
    LocalSettingsStore? store,
    SettingsCatalogBridge? bridge,
    required T Function<T>(ProviderListenable<T> provider) read,
  })  : _store = store ?? LocalSettingsStore(),
        _bridge = bridge ?? SettingsCatalogBridge(),
        _providerRead = read {
    AccountSettingsScope.addListener((_) async {
      final SettingsCatalog catalog =
          _catalog ?? await _providerRead(settingsCatalogProvider.future);
      await load(catalog, force: true);
      await _refreshLegacyNotifiers();
      try {
        await _providerRead(privateModeStateProvider).load();
      } catch (_) {}
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
    switch (def.type) {
      case 'boolean':
        return _store.getBool(key, def.defaultValue == true);
      case 'number':
        return _store.getInt(key, (def.defaultValue as num?)?.toInt() ?? 0);
      case 'multi_select':
        final saved = await _store.getStringList(key);
        if (saved.isNotEmpty) return saved;
        if (def.defaultValue is List) {
          return (def.defaultValue as List).map((e) => e.toString()).toList();
        }
        return saved;
      case 'single_select':
      case 'text':
      default:
        return _store.getString(key, def.defaultValue?.toString() ?? '');
    }
  }

  Future<void> setValue(SettingDef def, Object? value) async {
    _values[def.id] = value;
    notifyListeners();
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
    await _bridge.onCatalogChanged(def, value);
    if (def.id == 'messages.auto_delete_enabled' || def.id == 'messages.auto_delete_ttl') {
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
    if (_catalog != null) {
      await ProfileSettingsSync().pushIfNeeded(_catalog!, def, value);
    }
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
  await AppConfig.refreshFromCatalog();
  final catalog = await read(settingsCatalogProvider.future);
  await CatalogSeedService().maybeAutoSeed(catalog);
  await read(settingsCatalogValuesProvider).load(catalog);
}
