import 'local_settings_store.dart';

/// Locally saved contact display names (aliases) — server has no contact book.
class ContactStore {
  final _store = LocalSettingsStore();

  Future<String?> getAlias(String userId) async {
    final value = await _store.getString('contact_alias_$userId', '');
    return value.isEmpty ? null : value;
  }

  Future<void> setAlias(String userId, String name) async {
    await _store.setString('contact_alias_$userId', name.trim());
  }
}

/// Reads all saved contact aliases on boot.
Future<Map<String, String>> loadAllContactAliases() async {
  final entries = await LocalSettingsStore().getStringEntries('contact_alias_');
  entries.removeWhere((_, name) => name.isEmpty);
  return entries;
}
