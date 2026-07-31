import 'local_settings_store.dart';
import 'settings_catalog_bridge.dart';

/// Persisted string lists for catalog settings of type `list`.
class CatalogListStore {
  CatalogListStore({LocalSettingsStore? store}) : _store = store ?? LocalSettingsStore();

  final LocalSettingsStore _store;

  Future<List<String>> load(String settingId) =>
      _store.getStringList(SettingsCatalogBridge.catalogKey('list.$settingId'));

  Future<void> save(String settingId, List<String> items) =>
      _store.setStringList(SettingsCatalogBridge.catalogKey('list.$settingId'), items);

  Future<void> add(String settingId, String item) async {
    final list = await load(settingId);
    if (!list.contains(item)) {
      list.add(item);
      await save(settingId, list);
    }
  }

  Future<void> remove(String settingId, String item) async {
    final list = await load(settingId);
    list.remove(item);
    await save(settingId, list);
  }
}
