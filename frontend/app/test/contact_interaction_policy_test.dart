import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/services/catalog_list_store.dart';
import 'package:messenger_app/services/contact_interaction_policy.dart';
import 'package:messenger_app/services/local_settings_store.dart';
import 'package:messenger_app/services/settings_catalog_bridge.dart';
import 'package:messenger_app/services/settings_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalSettingsStore store;
  late SettingsRuntime runtime;
  late ContactInteractionPolicy policy;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LocalSettingsStore.setActiveUser('local-user');
    store = LocalSettingsStore();
    runtime = SettingsRuntime(
      reader: CatalogSettingsReader(store: store),
      lists: CatalogListStore(store: store),
    );
    policy = ContactInteractionPolicy(runtime: runtime);
  });

  test(
    'blocked peer cannot send messages, call, or receive new traffic',
    () async {
      await runtime.blockUser('blocked-peer');

      expect(await policy.canInitiate('blocked-peer'), isFalse);
      expect(
        await policy.canReceiveMessage(
          'blocked-peer',
          isContact: true,
          hasPriorOutgoing: true,
        ),
        isFalse,
      );
      expect(
        await policy.canReceiveCall('blocked-peer', isContact: true),
        isFalse,
      );
    },
  );

  test(
    'unblocked established peer is not rejected by invite-only policy',
    () async {
      await store.setString(
        SettingsCatalogBridge.catalogKey('privacy.incoming_messages'),
        'nobody',
      );

      expect(
        await policy.canReceiveMessage(
          'known-peer',
          isContact: true,
          hasPriorOutgoing: true,
        ),
        isTrue,
      );
      expect(
        await policy.canReceiveMessage(
          'new-peer',
          isContact: false,
          hasPriorOutgoing: false,
        ),
        isFalse,
      );
    },
  );

  test('call allow-list still applies after blocked-user check', () async {
    await store.setString(
      SettingsCatalogBridge.catalogKey('privacy.calls_from'),
      'contacts',
    );

    expect(await policy.canReceiveCall('contact', isContact: true), isTrue);
    expect(await policy.canReceiveCall('stranger', isContact: false), isFalse);
  });
}
