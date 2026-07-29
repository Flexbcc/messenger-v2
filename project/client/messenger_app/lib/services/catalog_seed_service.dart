import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/settings_catalog.dart';
import 'catalog_list_store.dart';
import 'catalog_sync.dart';
import 'local_settings_store.dart';
import 'settings_catalog_bridge.dart';

/// Dev/test seeding and JSON blob import/export for catalog values.
///
/// Storage today: SharedPreferences via [LocalSettingsStore] — one typed key per
/// setting (`app_settings_catalog.profile.display_name`), not SQLite.
/// This service also keeps a single JSON snapshot at [blobKey] for debugging.
class CatalogSeedService {
  CatalogSeedService({
    LocalSettingsStore? store,
    CatalogListStore? lists,
    SettingsCatalogBridge? bridge,
  })  : _store = store ?? LocalSettingsStore(),
        _lists = lists ?? CatalogListStore(),
        _bridge = bridge ?? SettingsCatalogBridge();

  final LocalSettingsStore _store;
  final CatalogListStore _lists;
  final SettingsCatalogBridge _bridge;

  static const seedAsset = 'assets/settings/dev-catalog-seed.json';
  static const blobKey = 'catalog.values_blob';
  static const seededFlag = 'catalog.dev_seeded';

  /// `profile_avatar` → `profile.avatar`; dot keys pass through unchanged.
  static String normalizeKey(String raw) {
    final k = raw.trim();
    if (k.contains('.')) return k;
    final i = k.indexOf('_');
    if (i <= 0) return k;
    return '${k.substring(0, i)}.${k.substring(i + 1)}';
  }

  /// Load bundled dev seed and apply (debug / manual trigger).
  Future<int> applyDevSeedAsset(SettingsCatalog catalog) async {
    final raw = await rootBundle.loadString(seedAsset);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return applyJson(catalog, json);
  }

  /// Apply `{ "values": { "profile_display_name": "..." }, "lists": { ... } }`.
  Future<int> applyJson(SettingsCatalog catalog, Map<String, dynamic> json) async {
    final values = (json['values'] as Map<String, dynamic>?) ?? const {};
    final lists = (json['lists'] as Map<String, dynamic>?) ?? const {};
    var count = 0;

    for (final entry in values.entries) {
      final id = normalizeKey(entry.key);
      final def = catalog.settingById(id);
      if (def == null || !def.isPersistable || def.isSecret) continue;
      await _writeValue(def, entry.value);
      count++;
    }

    for (final entry in lists.entries) {
      final id = normalizeKey(entry.key);
      final def = catalog.settingById(id);
      if (def == null || def.type != 'list') continue;
      final items = _asStringList(entry.value);
      await _lists.save(id, items);
      count++;
    }

    await _pushLegacyFromCatalog(catalog);
    await _saveBlob(catalog);
    await _store.setBool(seededFlag, true);
    return count;
  }

  /// Export all persistable catalog values to one JSON map (snake_case keys).
  Future<Map<String, dynamic>> exportJson(SettingsCatalog catalog) async {
    final values = <String, dynamic>{};
    final lists = <String, dynamic>{};

    for (final section in catalog.sections) {
      for (final def in section.settings) {
        if (!def.isPersistable || def.isSecret) continue;
        final snake = def.id.replaceAll('.', '_');
        if (def.type == 'list') {
          lists[snake] = await _lists.load(def.id);
        } else {
          values[snake] = await _readValue(def);
        }
      }
    }

    return {
      'meta': {
        'exported_at': DateTime.now().toIso8601String(),
        'format': 'snake_case keys → profile_display_name = "..."',
      },
      'values': values,
      'lists': lists,
    };
  }

  /// Read last saved blob from prefs (may be stale until export/seed).
  Future<Map<String, dynamic>?> loadBlob() async {
    final raw = await _store.getString(blobKey, '');
    if (raw.isEmpty) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Auto-fill on first debug boot when nothing seeded yet.
  /// Only seeds into an **active account** namespace — never into unscoped
  /// prefs (those would leak across accounts).
  Future<void> maybeAutoSeed(SettingsCatalog catalog) async {
    if (!kDebugMode) return;
    if (LocalSettingsStore.activeUserId == null) return;
    final done = await _store.getBool(seededFlag, false);
    if (done) return;
    final probe = await _store.getString(SettingsCatalogBridge.catalogKey('profile.bio'), '');
    if (probe.isNotEmpty) {
      await _store.setBool(seededFlag, true);
      return;
    }
    await applyDevSeedAsset(catalog);
  }

  Future<void> _writeValue(SettingDef def, Object? value) async {
    final key = SettingsCatalogBridge.catalogKey(def.id);
    switch (def.type) {
      case 'boolean':
        await _store.setBool(key, value == true);
        break;
      case 'number':
        if (value is num) {
          await _store.setInt(key, value.toInt());
        } else {
          await _store.setInt(key, int.tryParse(value?.toString() ?? '') ?? 0);
        }
        break;
      case 'multi_select':
        await _store.setStringList(key, _asStringList(value));
        break;
      default:
        await _store.setString(key, value?.toString() ?? '');
    }
  }

  Future<Object?> _readValue(SettingDef def) async {
    final key = SettingsCatalogBridge.catalogKey(def.id);
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
      default:
        return _store.getString(key, def.defaultValue?.toString() ?? '');
    }
  }

  Future<void> _pushLegacyFromCatalog(SettingsCatalog catalog) async {
    const legacyIds = {
      'appearance.theme',
      'notifications.enabled',
      'notifications.preview',
      'notifications.types',
      'notifications.dnd_enabled',
      'notifications.hidden_chat_policy',
      'security.lock_on_background',
      'security.autolock',
      'security.fake_pin_enabled',
      'security.wipe_enabled',
      'privacy.invisible_mode',
      'hidden.enabled',
      'hidden.hide_from_search',
      'hidden.hide_notifications',
      'media.autoload_wifi',
      'media.autoload_mobile',
      'devices.require_approval',
    };
    for (final id in legacyIds) {
      final def = catalog.settingById(id);
      if (def == null) continue;
      final v = await _readValue(def);
      await _bridge.onCatalogChanged(def, v);
    }
    await CatalogSync.syncAllFromLegacy();
  }

  Future<void> _saveBlob(SettingsCatalog catalog) async {
    final blob = await exportJson(catalog);
    await _store.setString(blobKey, jsonEncode(blob));
  }

  static List<String> _asStringList(Object? value) {
    if (value is List) return value.map((e) => e.toString()).toList();
    return const [];
  }
}
