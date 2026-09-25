import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/models/chat_draft.dart';
import 'package:messenger_app/services/chat_draft_store.dart';
import 'package:messenger_app/services/catalog_list_store.dart';
import 'package:messenger_app/services/local_settings_store.dart';
import 'package:messenger_app/services/settings_catalog_bridge.dart';
import 'package:messenger_app/services/settings_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LocalSettingsStore.setActiveUser(null);
  });

  test('extra-large appearance setting has a distinct text scale', () async {
    final store = LocalSettingsStore();
    await store.setString(
      SettingsCatalogBridge.catalogKey('appearance.text_size'),
      'extra_large',
    );

    final runtime = SettingsRuntime(
      reader: CatalogSettingsReader(store: store),
    );
    expect(await runtime.textScaleFactor(), 1.3);
  });

  test('contact block can be applied and revoked', () async {
    final store = LocalSettingsStore();
    final runtime = SettingsRuntime(
      reader: CatalogSettingsReader(store: store),
      lists: CatalogListStore(store: store),
    );

    expect(await runtime.isBlocked('peer-1'), isFalse);
    await runtime.blockUser('peer-1');
    expect(await runtime.isBlocked('peer-1'), isTrue);
    await runtime.unblockUser('peer-1');
    expect(await runtime.isBlocked('peer-1'), isFalse);
  });

  test(
    'contact block survives runtime restart and stays account-scoped',
    () async {
      LocalSettingsStore.setActiveUser('bob');
      var store = LocalSettingsStore();
      var runtime = SettingsRuntime(
        reader: CatalogSettingsReader(store: store),
        lists: CatalogListStore(store: store),
      );
      await runtime.blockUser('alice');

      // New service objects model a client/runtime restart.
      store = LocalSettingsStore();
      runtime = SettingsRuntime(
        reader: CatalogSettingsReader(store: store),
        lists: CatalogListStore(store: store),
      );
      expect(await runtime.isBlocked('alice'), isTrue);

      // Another local account has an independent decision and can block Bob in
      // the opposite direction without overwriting Bob's list.
      LocalSettingsStore.setActiveUser('alice');
      store = LocalSettingsStore();
      runtime = SettingsRuntime(
        reader: CatalogSettingsReader(store: store),
        lists: CatalogListStore(store: store),
      );
      expect(await runtime.isBlocked('bob'), isFalse);
      await runtime.blockUser('bob');
      expect(await runtime.isBlocked('bob'), isTrue);

      LocalSettingsStore.setActiveUser('bob');
      store = LocalSettingsStore();
      runtime = SettingsRuntime(
        reader: CatalogSettingsReader(store: store),
        lists: CatalogListStore(store: store),
      );
      expect(await runtime.isBlocked('alice'), isTrue);
    },
  );

  test(
    'disabled draft setting removes and does not restore an old draft',
    () async {
      final store = LocalSettingsStore();
      const conversationId = 'draft-contract-test';
      await store.setBool(
        SettingsCatalogBridge.catalogKey('messages.save_drafts'),
        true,
      );
      await ChatDraftStore.instance.save(
        conversationId,
        const ChatDraft(text: 'must disappear'),
      );

      await store.setBool(
        SettingsCatalogBridge.catalogKey('messages.save_drafts'),
        false,
      );

      expect(
        (await ChatDraftStore.instance.get(conversationId)).isEmpty,
        isTrue,
      );
      expect(await store.getString('chat_draft_$conversationId', ''), '');
    },
  );

  test('auto-delete TTL is applied only when enabled', () async {
    final store = LocalSettingsStore();
    final runtime = SettingsRuntime(
      reader: CatalogSettingsReader(store: store),
    );

    await store.setString(
      SettingsCatalogBridge.catalogKey('messages.auto_delete_ttl'),
      '7d',
    );
    await store.setBool(
      SettingsCatalogBridge.catalogKey('messages.auto_delete_enabled'),
      false,
    );
    expect(await runtime.outgoingAutoDeleteSeconds(), isNull);

    await store.setBool(
      SettingsCatalogBridge.catalogKey('messages.auto_delete_enabled'),
      true,
    );
    expect(await runtime.outgoingAutoDeleteSeconds(), 7 * 24 * 60 * 60);
  });

  test('history loading honors sync switch and depth', () async {
    final store = LocalSettingsStore();
    final runtime = SettingsRuntime(
      reader: CatalogSettingsReader(store: store),
    );

    await store.setBool(
      SettingsCatalogBridge.catalogKey('sync.enabled'),
      false,
    );
    expect(await runtime.messageHistorySyncAllowed(), isFalse);

    await store.setBool(SettingsCatalogBridge.catalogKey('sync.enabled'), true);
    await store.setString(
      SettingsCatalogBridge.catalogKey('sync.history_depth'),
      '7d',
    );
    expect(await runtime.messageHistorySyncAllowed(), isTrue);
    expect(await runtime.historySyncMaxAge(), const Duration(days: 7));
  });

  test('local media TTL is applied only when enabled', () async {
    final store = LocalSettingsStore();
    final runtime = SettingsRuntime(
      reader: CatalogSettingsReader(store: store),
    );

    await store.setString(
      SettingsCatalogBridge.catalogKey('storage.media_ttl'),
      '30d',
    );
    await store.setBool(
      SettingsCatalogBridge.catalogKey('storage.media_ttl_enabled'),
      false,
    );
    expect(await runtime.mediaTtlMaxAge(), isNull);

    await store.setBool(
      SettingsCatalogBridge.catalogKey('storage.media_ttl_enabled'),
      true,
    );
    expect(await runtime.mediaTtlMaxAge(), const Duration(days: 30));
  });
}
