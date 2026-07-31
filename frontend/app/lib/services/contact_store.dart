import 'package:shared_preferences/shared_preferences.dart';

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
  final prefs = await SharedPreferences.getInstance();
  const prefix = 'app_settings_contact_alias_';
  final result = <String, String>{};
  for (final key in prefs.getKeys()) {
    if (key.startsWith(prefix)) {
      final userId = key.substring(prefix.length);
      final name = prefs.getString(key);
      if (name != null && name.isNotEmpty) result[userId] = name;
    }
  }
  return result;
}
