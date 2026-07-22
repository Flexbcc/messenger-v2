import 'package:flutter/material.dart';

import '../models/settings_catalog.dart';
import '../services/app_lock_service.dart';
import '../state/notification_settings.dart';
import '../state/theme_settings.dart';
import 'hidden_chats_store.dart';
import 'local_settings_store.dart';
import 'login_approval_service.dart';
import 'privacy_preferences_store.dart';

/// Applies catalog edits to legacy runtime stores (catalog → legacy).
/// Legacy → catalog is [CatalogSync].
class SettingsCatalogBridge {
  SettingsCatalogBridge({LocalSettingsStore? store}) : _store = store ?? LocalSettingsStore();

  final LocalSettingsStore _store;

  static String catalogKey(String id) => 'catalog.$id';

  /// Push a single catalog change into legacy stores.
  Future<void> onCatalogChanged(SettingDef def, Object? value) async {
    await _applyOne(def.id, value);
    await _recalcMediaIfNeeded(def.id);
  }

  Future<void> _applyOne(String id, Object? value) async {
    switch (id) {
      case 'appearance.theme':
        await _store.setString('theme_mode', value?.toString() ?? 'system');
        break;
      case 'notifications.enabled':
        await _store.setBool('notif_enabled', value == true);
        break;
      case 'notifications.preview':
        await _store.setString('notif_preview', _previewToLegacy(value?.toString()));
        break;
      case 'notifications.types':
        final types = _asStringList(value);
        await _store.setStringList(catalogKey('notifications.types'), types);
        await _store.setString(
          'notif_direct',
          types.contains('direct') ? 'Все сообщения' : 'Выключено',
        );
        final groupOn = types.contains('groups') ||
            types.contains('mentions') ||
            types.contains('replies');
        await _store.setString(
          'notif_groups',
          groupOn
              ? (types.contains('groups') ? 'Все сообщения' : 'Только упоминания')
              : 'Выключено',
        );
        await _store.setString(
          'notif_calls',
          types.contains('calls') ? 'Все' : 'Выключено',
        );
        break;
      case 'notifications.dnd_enabled':
        await _store.setBool(catalogKey('notifications.dnd_enabled'), value == true);
        break;
      case 'notifications.hidden_chat_policy':
        final policy = value?.toString() ?? 'none';
        await _store.setString(catalogKey('notifications.hidden_chat_policy'), policy);
        await _store.setString('notif_hidden', _hiddenPolicyToLegacy(policy));
        break;
      case 'security.pin_enabled':
        await PrivacyPreferencesStore().setPinEnabled(value == true);
        await AppLockService.instance.refreshEnabled();
        break;
      case 'security.lock_on_background':
        await PrivacyPreferencesStore().setLockOnBackground(value == true);
        await AppLockService.instance.refreshEnabled();
        break;
      case 'security.lock_on_screen_off':
        await AppLockService.instance.refreshEnabled();
        break;
      case 'security.autolock':
        await PrivacyPreferencesStore().setAutoLockSeconds(_autolockToSeconds(value?.toString()));
        break;
      case 'security.fake_pin_enabled':
        await PrivacyPreferencesStore().setFakePinEnabled(value == true);
        break;
      case 'security.wipe_enabled':
        await PrivacyPreferencesStore().setWipeOnWrongAttempts(value == true);
        break;
      case 'privacy.invisible_mode':
        await PrivacyPreferencesStore().setInvisibleMode(value == true);
        break;
      case 'hidden.enabled':
        await PrivacyPreferencesStore().setHiddenChatsEnabled(value == true);
        break;
      case 'hidden.open_method':
        final method = value?.toString() ?? 'pin';
        await HiddenChatsStore.instance.setOpenMethod(method);
        await HiddenChatsStore.instance.setGestureEntryEnabled(method == 'gesture');
        break;
      case 'hidden.hide_from_search':
        await HiddenChatsStore.instance.setExcludeFromGlobalSearch(value == true);
        break;
      case 'hidden.hide_notifications':
        await HiddenChatsStore.instance.setSilenceNotifications(value == true);
        break;
      case 'hidden.hide_media':
        await HiddenChatsStore.instance.setHideMediaFromGallery(value == true);
        break;
      case 'hidden.autolock':
        await HiddenChatsStore.instance.setAutolock(value?.toString() ?? '1m');
        break;
      case 'hidden.chat_list':
        // List edits go through CatalogListStore; sync is handled in SettingsCatalogActions.
        break;
      case 'contacts.trusted_enabled':
        await _store.setBool(catalogKey('contacts.trusted_enabled'), value == true);
        break;
      case 'contacts.trusted_list':
        break;
      case 'devices.require_approval':
        await LoginApprovalService.instance.setEnabled(value == true);
        break;
      default:
        break;
    }
  }

  Future<void> _recalcMediaIfNeeded(String id) async {
    if (id != 'media.autoload_wifi' && id != 'media.autoload_mobile') return;
    await _syncAllMediaAutoload();
  }

  Future<void> _syncAllMediaAutoload() async {
    final wifiKinds = await _store.getStringList(catalogKey('media.autoload_wifi'));
    final mobileKinds = await _store.getStringList(catalogKey('media.autoload_mobile'));
    for (final kind in ['photos', 'videos', 'audio', 'files']) {
      final key = 'dl_$kind';
      final onWifi = wifiKinds.contains(kind);
      final onMobile = mobileKinds.contains(kind);
      final mode = !onWifi && !onMobile
          ? 'never'
          : onMobile
              ? 'wifiAndMobile'
              : 'wifi';
      await _store.setString(key, mode);
    }
  }

  static List<String> _asStringList(Object? value) {
    if (value is List) return value.map((e) => e.toString()).toList();
    return const [];
  }

  static String _previewToLegacy(String? spec) => switch (spec) {
        'full' => 'Полный текст',
        'sender_only' => 'Только имя отправителя',
        'hidden' => 'Скрыто',
        'app_only' => 'Только приложение',
        _ => 'Полный текст',
      };

  static int _autolockToSeconds(String? spec) => switch (spec) {
        'immediately' => 0,
        '30s' => 30,
        '1m' => 60,
        '5m' => 300,
        '15m' => 900,
        '1h' => 3600,
        'never' => -1,
        _ => 300,
      };

  static String _hiddenPolicyToLegacy(String policy) => switch (policy) {
        'normal' || 'all' => 'Все сообщения',
        'generic' || 'mentions' => 'Только упоминания',
        _ => 'Выключено',
      };

  Future<void> refreshLegacyNotifiers({
    ThemeSettings? theme,
    NotificationSettings? notifications,
  }) async {
    if (theme != null) {
      final stored = await _store.getString('theme_mode', 'system');
      await theme.setMode(switch (stored) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      });
    }
    if (notifications != null) {
      await notifications.reloadFromStore();
    }
    await AppLockService.instance.refreshEnabled();
  }
}

/// Reads catalog-persisted values for async services (no Riverpod required).
class CatalogSettingsReader {
  CatalogSettingsReader({LocalSettingsStore? store}) : _store = store ?? LocalSettingsStore();

  final LocalSettingsStore _store;

  Future<bool> getBool(String id, bool fallback) =>
      _store.getBool(SettingsCatalogBridge.catalogKey(id), fallback);

  Future<String> getString(String id, String fallback) =>
      _store.getString(SettingsCatalogBridge.catalogKey(id), fallback);

  Future<int> getInt(String id, int fallback) =>
      _store.getInt(SettingsCatalogBridge.catalogKey(id), fallback);

  Future<List<String>> getStringList(String id) =>
      _store.getStringList(SettingsCatalogBridge.catalogKey(id));

  Future<bool> draftsEnabled() => getBool('messages.save_drafts', true);

  Future<String> sendKey() => getString('messages.send_key', 'enter');

  Future<bool> linkPreviewEnabled() async {
    final mode = await getString('messages.link_preview', 'local_only');
    return mode != 'off';
  }

  Future<bool> notificationsEnabled() => getBool('notifications.enabled', true);

  Future<bool> developerEnabled() => getBool('developer.enabled', false);
}
