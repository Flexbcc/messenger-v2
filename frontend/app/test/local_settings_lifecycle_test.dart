import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/models/settings_catalog.dart';
import 'package:messenger_app/services/local_settings_store.dart';
import 'package:messenger_app/services/settings_catalog_bridge.dart';
import 'package:messenger_app/services/settings_runtime.dart';
import 'package:messenger_app/state/notification_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LocalSettingsStore.setActiveUser(null);
  });

  SettingDef setting(String id, String type, Object? defaultValue) {
    return SettingDef.fromJson({
      'id': id,
      'title': id,
      'type': type,
      'default': defaultValue,
      'storage': 'profile_settings',
    });
  }

  Future<void> save(SettingDef def, Object? value) async {
    final store = LocalSettingsStore();
    final key = SettingsCatalogBridge.catalogKey(def.id);
    switch (def.type) {
      case 'boolean':
        await store.setBool(key, value == true);
        break;
      case 'multi_select':
        await store.setStringList(
          key,
          (value as List).map((e) => e.toString()).toList(),
        );
        break;
      default:
        await store.setString(key, value.toString());
        break;
    }
    await SettingsCatalogBridge(store: store).onCatalogChanged(def, value);
  }

  test('representative settings survive runtime recreation', () async {
    LocalSettingsStore.setActiveUser('user-a');
    await save(setting('appearance.theme', 'single_select', 'system'), 'dark');
    await save(
      setting('notifications.preview', 'single_select', 'full'),
      'hidden',
    );
    await save(
      setting('messages.send_key', 'single_select', 'enter'),
      'ctrl_enter',
    );
    await save(setting('privacy.read_receipts', 'boolean', true), false);

    // Fresh objects represent a new client process reading persisted values.
    final runtime = SettingsRuntime(
      reader: CatalogSettingsReader(store: LocalSettingsStore()),
    );
    final notifications = NotificationSettings.forTesting();
    await notifications.reloadFromStore();

    expect(await runtime.themeMode(), 'dark');
    expect(await runtime.sendKey(), 'ctrl_enter');
    expect(await runtime.readReceiptsEnabled(), isFalse);
    expect(notifications.preview, 'Скрыто');
  });

  test('account switch restores each account settings independently', () async {
    LocalSettingsStore.setActiveUser('user-a');
    await save(setting('appearance.theme', 'single_select', 'system'), 'dark');
    await save(
      setting('messages.send_key', 'single_select', 'enter'),
      'ctrl_enter',
    );
    await save(setting('privacy.read_receipts', 'boolean', true), false);

    LocalSettingsStore.setActiveUser('user-b');
    var runtime = SettingsRuntime(
      reader: CatalogSettingsReader(store: LocalSettingsStore()),
    );
    expect(await runtime.themeMode(), 'system');
    expect(await runtime.sendKey(), 'enter');
    expect(await runtime.readReceiptsEnabled(), isTrue);

    await save(setting('appearance.theme', 'single_select', 'system'), 'light');
    await save(setting('messages.send_key', 'single_select', 'enter'), 'enter');

    LocalSettingsStore.setActiveUser('user-a');
    runtime = SettingsRuntime(
      reader: CatalogSettingsReader(store: LocalSettingsStore()),
    );
    expect(await runtime.themeMode(), 'dark');
    expect(await runtime.sendKey(), 'ctrl_enter');
    expect(await runtime.readReceiptsEnabled(), isFalse);

    LocalSettingsStore.setActiveUser('user-b');
    runtime = SettingsRuntime(
      reader: CatalogSettingsReader(store: LocalSettingsStore()),
    );
    expect(await runtime.themeMode(), 'light');
    expect(await runtime.sendKey(), 'enter');
    expect(await runtime.readReceiptsEnabled(), isTrue);
  });

  test('signed-in settings are written only to account-scoped keys', () async {
    LocalSettingsStore.setActiveUser('user-a');
    await save(setting('appearance.theme', 'single_select', 'system'), 'dark');
    await save(
      setting('notifications.preview', 'single_select', 'full'),
      'hidden',
    );

    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    expect(keys, contains('app_settings_u_user-a_catalog.appearance.theme'));
    expect(keys, contains('app_settings_u_user-a_theme_mode'));
    expect(
      keys,
      contains('app_settings_u_user-a_catalog.notifications.preview'),
    );
    expect(keys, contains('app_settings_u_user-a_notif_preview'));
    expect(keys.where((key) => key == 'app_settings_theme_mode'), isEmpty);
    expect(
      keys.where((key) => key == 'app_settings_catalog.appearance.theme'),
      isEmpty,
    );
  });
}
