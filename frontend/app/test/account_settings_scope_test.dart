import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/security/pin_security.dart';
import 'package:messenger_app/services/account_settings_scope.dart';
import 'package:messenger_app/services/local_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    LocalSettingsStore.setActiveUser(null);
    PinSecurity.setActiveUser(null);
  });

  test('settings do not leak across users', () async {
    final store = LocalSettingsStore();

    LocalSettingsStore.setActiveUser('user-a');
    await store.setString('catalog.profile.display_name', 'Alice');
    await store.setBool('pm_app_lock', true);

    LocalSettingsStore.setActiveUser('user-b');
    expect(await store.getString('catalog.profile.display_name', ''), '');
    expect(await store.getBool('pm_app_lock', false), isFalse);

    LocalSettingsStore.setActiveUser('user-a');
    expect(await store.getString('catalog.profile.display_name', ''), 'Alice');
    expect(await store.getBool('pm_app_lock', false), isTrue);
  });

  test('clearActiveUserData only wipes current user', () async {
    final store = LocalSettingsStore();
    LocalSettingsStore.setActiveUser('user-a');
    await store.setString('catalog.profile.bio', 'a');
    LocalSettingsStore.setActiveUser('user-b');
    await store.setString('catalog.profile.bio', 'b');

    LocalSettingsStore.setActiveUser('user-a');
    await LocalSettingsStore.clearActiveUserData();
    expect(await store.getString('catalog.profile.bio', ''), '');

    LocalSettingsStore.setActiveUser('user-b');
    expect(await store.getString('catalog.profile.bio', ''), 'b');
  });

  test(
    'wipeUser keeps active account scope while the session remains active',
    () async {
      final store = LocalSettingsStore();
      LocalSettingsStore.setActiveUser('user-a');
      PinSecurity.setActiveUser('user-a');
      await store.setString('catalog.profile.bio', 'before');

      await AccountSettingsScope.wipeUser('user-a');

      expect(LocalSettingsStore.activeUserId, 'user-a');
      expect(await store.getString('catalog.profile.bio', ''), '');

      await store.setString('catalog.profile.bio', 'after');
      expect(await store.getString('catalog.profile.bio', ''), 'after');

      LocalSettingsStore.setActiveUser(null);
      expect(await store.getString('catalog.profile.bio', ''), '');
    },
  );
}
