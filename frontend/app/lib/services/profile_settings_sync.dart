import '../models/settings_catalog.dart';
import 'api_client.dart';
import 'catalog_list_store.dart';
import 'local_settings_store.dart';
import 'settings_catalog_bridge.dart';

/// Syncs profile-scoped catalog values with Home Node (`/users/me/profile-settings`).
class ProfileSettingsSync {
  ProfileSettingsSync({
    LocalSettingsStore? store,
    CatalogListStore? lists,
  })  : _store = store ?? LocalSettingsStore(),
        _lists = lists ?? CatalogListStore();

  /// Set after login so catalog edits sync to Home Node.
  static ApiClient? api;

  /// Loaded catalog — required for full blob export.
  static SettingsCatalog? catalog;

  final LocalSettingsStore _store;
  final CatalogListStore _lists;

  /// Pull server profile + settings blob into local catalog on boot.
  Future<void> pullFromServer(ApiClient api, SettingsCatalog catalog) async {
    ProfileSettingsSync.catalog = catalog;
    try {
      final me = await api.getMyProfile();
      await _applyMeFields(me, catalog);
      final blob = await api.getProfileSettings();
      if (blob.isNotEmpty) {
        await _applyBlob(catalog, blob);
      }
    } catch (_) {
      // Offline / old backend — local catalog remains source of truth.
    }
  }

  /// Push catalog change to server when it is profile-scoped.
  Future<void> pushIfNeeded(SettingsCatalog catalog, SettingDef def, Object? value) async {
    ProfileSettingsSync.catalog = catalog;
    final api = ProfileSettingsSync.api;
    if (api == null) return;

    if (def.id == 'profile.username_enabled' && value != true) {
      await api.updateProfile(login: '');
    }

    if (_isTopLevelProfileField(def.id)) {
      await _pushProfileField(api, def.id, value);
      return;
    }

    if (def.scope == 'profile' && def.storage == 'profile_settings' && !def.isSecret) {
      await _pushProfileSettingsBlob(api, catalog);
    }
  }

  bool _isTopLevelProfileField(String id) => switch (id) {
        'profile.display_name' ||
        'profile.username' ||
        'profile.bio' ||
        'identity.phone' ||
        'identity.email' =>
          true,
        _ => false,
      };

  Future<void> _pushProfileField(ApiClient api, String id, Object? value) async {
    switch (id) {
      case 'profile.display_name':
        final name = value?.toString().trim() ?? '';
        if (name.isNotEmpty) await api.updateProfile(displayName: name);
      case 'profile.username':
        final enabled = await _store.getBool(
          SettingsCatalogBridge.catalogKey('profile.username_enabled'),
          false,
        );
        if (enabled) {
          await api.updateProfile(login: value?.toString() ?? '');
        }
      case 'profile.bio':
        await api.updateProfile(bio: value?.toString());
      case 'identity.phone':
        await api.updateProfile(phone: value?.toString());
      case 'identity.email':
        await api.updateProfile(email: value?.toString());
    }
    if (ProfileSettingsSync.catalog != null) {
      await _pushProfileSettingsBlob(api, ProfileSettingsSync.catalog!);
    }
  }

  Future<void> _pushProfileSettingsBlob(ApiClient api, SettingsCatalog catalog) async {
    final values = <String, dynamic>{};
    final lists = <String, dynamic>{};

    for (final section in catalog.sections) {
      for (final def in section.settings) {
        if (def.scope != 'profile' || def.storage != 'profile_settings') continue;
        if (!def.isPersistable || def.isSecret) continue;
        if (def.type == 'list') {
          lists[def.id] = await _lists.load(def.id);
          continue;
        }
        values[def.id] = await _readValue(def);
      }
    }

    await api.updateProfileSettings({'values': values, 'lists': lists});
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

  Future<void> _applyMeFields(Map<String, dynamic> me, SettingsCatalog catalog) async {
    final displayName = me['display_name'] as String?;
    if (displayName != null && displayName.isNotEmpty) {
      await _store.setString(SettingsCatalogBridge.catalogKey('profile.display_name'), displayName);
    }
    final login = me['login'] as String?;
    if (login != null && login.isNotEmpty) {
      await _store.setString(SettingsCatalogBridge.catalogKey('profile.username'), login);
      await _store.setBool(SettingsCatalogBridge.catalogKey('profile.username_enabled'), true);
    } else {
      await _store.setBool(SettingsCatalogBridge.catalogKey('profile.username_enabled'), false);
    }
    final bio = me['bio'] as String?;
    if (bio != null) {
      await _store.setString(SettingsCatalogBridge.catalogKey('profile.bio'), bio);
    }
    final phone = me['phone'] as String?;
    if (phone != null && phone.isNotEmpty) {
      await _store.setString(SettingsCatalogBridge.catalogKey('identity.phone'), phone);
      await _store.setBool(SettingsCatalogBridge.catalogKey('identity.phone_enabled'), true);
    }
    final email = me['email'] as String?;
    if (email != null && email.isNotEmpty) {
      await _store.setString(SettingsCatalogBridge.catalogKey('identity.email'), email);
      await _store.setBool(SettingsCatalogBridge.catalogKey('identity.email_enabled'), true);
    }
  }

  Future<void> _applyBlob(SettingsCatalog catalog, Map<String, dynamic> blob) async {
    final values = blob['values'] as Map<String, dynamic>? ?? const {};
    for (final entry in values.entries) {
      final def = catalog.settingById(entry.key);
      if (def == null || !def.isPersistable || def.isSecret) continue;
      await _writeValue(def, entry.value);
    }
    final lists = blob['lists'] as Map<String, dynamic>? ?? const {};
    for (final entry in lists.entries) {
      if (entry.value is List) {
        await _lists.save(
          entry.key,
          (entry.value as List).map((e) => e.toString()).toList(),
        );
      }
    }
  }

  Future<void> _writeValue(SettingDef def, Object? value) async {
    final key = SettingsCatalogBridge.catalogKey(def.id);
    switch (def.type) {
      case 'boolean':
        await _store.setBool(key, value == true);
      case 'number':
        await _store.setInt(key, (value as num?)?.toInt() ?? 0);
      case 'multi_select':
        if (value is List) {
          await _store.setStringList(key, value.map((e) => e.toString()).toList());
        }
      default:
        await _store.setString(key, value?.toString() ?? '');
    }
  }
}
