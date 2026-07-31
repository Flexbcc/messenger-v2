import 'hidden_chats_store.dart';
import 'local_settings_store.dart';
import 'login_approval_service.dart';
import 'privacy_preferences_store.dart';

/// Legacy screens / stores are the source of truth. This helper mirrors their
/// values into `catalog.<id>` so the spec catalog stays aligned without
/// replacing the familiar UI.
class CatalogSync {
  CatalogSync._();

  static final _store = LocalSettingsStore();

  static String _key(String id) => 'catalog.$id';

  /// Pull all mapped legacy keys into catalog (call before showing catalog UI).
  static Future<void> syncAllFromLegacy() async {
    await syncTheme();
    await syncNotifications();
    await syncPrivacy();
    await syncHidden();
    await syncMedia();
    await syncDevices();
  }

  static Future<void> syncTheme() async {
    final legacy = await _store.getString('theme_mode', 'system');
    await _store.setString(_key('appearance.theme'), legacy);
  }

  static Future<void> syncNotifications() async {
    final enabled = await _store.getBool('notif_enabled', true);
    final preview = await _store.getString('notif_preview', 'Полный текст');
    final direct = await _store.getString('notif_direct', 'Все сообщения');
    final groups = await _store.getString('notif_groups', 'Все сообщения');
    final calls = await _store.getString('notif_calls', 'Все');
    final hidden = await _store.getString('notif_hidden', 'Выключено');

    // The master switch is independent from sound. Muting sound must not
    // disable banners, calls, or browser notifications.
    await _store.setBool(_key('notifications.enabled'), enabled);
    await _store.setString(
      _key('notifications.preview'),
      _previewToSpec(preview),
    );

    final types = <String>[];
    if (direct != 'Выключено') types.add('direct');
    if (groups != 'Выключено') {
      types.add('mentions');
      types.add('replies');
    }
    if (calls != 'Выключено') types.add('calls');
    types.add('security');
    await _store.setStringList(_key('notifications.types'), types);

    await _store.setString(
      _key('notifications.hidden_chat_policy'),
      _hiddenToSpec(hidden),
    );
  }

  static Future<void> syncPrivacy() async {
    final privacy = PrivacyPreferencesStore();
    await _store.setBool(
      _key('security.lock_on_background'),
      await privacy.lockOnBackground(),
    );
    await _store.setBool(
      _key('security.fake_pin_enabled'),
      await privacy.fakePinEnabled(),
    );
    await _store.setBool(
      _key('security.wipe_enabled'),
      await privacy.wipeOnWrongAttempts(),
    );
    await _store.setBool(
      _key('hidden.enabled'),
      await privacy.hiddenChatsEnabled(),
    );
    await _store.setBool(
      _key('privacy.invisible_mode'),
      await privacy.maskNotifications(),
    );
    await _store.setString(
      _key('security.autolock'),
      _secondsToAutolock(await privacy.autoLockSeconds()),
    );
  }

  static Future<void> syncHidden() async {
    final store = HiddenChatsStore.instance;
    await _store.setBool(
      _key('hidden.hide_from_search'),
      await store.excludeFromGlobalSearch(),
    );
    await _store.setBool(
      _key('hidden.hide_notifications'),
      await store.silenceNotifications(),
    );
    await _store.setBool(
      _key('hidden.hide_media'),
      await store.hideMediaFromGallery(),
    );
    await _store.setString(
      _key('hidden.open_method'),
      await store.openMethod(),
    );
    await _store.setString(_key('hidden.autolock'), await store.autolock());
    await _store.setStringList(
      _key('list.hidden.chat_list'),
      (await store.loadSecretHiddenIds()).toList(),
    );
  }

  static Future<void> syncMedia() async {
    final wifi = <String>[];
    final mobile = <String>[];
    for (final kind in ['photos', 'videos', 'audio', 'files']) {
      final mode = await _store.getString('dl_$kind', 'wifi');
      if (mode == 'wifi' || mode == 'wifiAndMobile') wifi.add(kind);
      if (mode == 'wifiAndMobile') mobile.add(kind);
    }
    await _store.setStringList(_key('media.autoload_wifi'), wifi);
    await _store.setStringList(_key('media.autoload_mobile'), mobile);
  }

  static Future<void> syncDevices() async {
    await _store.setBool(
      _key('devices.require_approval'),
      await LoginApprovalService.instance.isEnabled(),
    );
  }

  static String _previewToSpec(String legacy) => switch (legacy) {
    'Полный текст' => 'full',
    'Только имя отправителя' => 'sender_only',
    'Скрыто' => 'hidden',
    'Только приложение' => 'app_only',
    _ => 'sender_only',
  };

  static String _hiddenToSpec(String legacy) => switch (legacy) {
    'Все сообщения' => 'normal',
    'Только упоминания' => 'generic',
    _ => 'none',
  };

  static String _secondsToAutolock(int seconds) => switch (seconds) {
    0 => 'immediate',
    <= 60 => '1m',
    <= 300 => '5m',
    <= 900 => '15m',
    _ => '1h',
  };
}
