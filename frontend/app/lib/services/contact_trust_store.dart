import 'package:shared_preferences/shared_preferences.dart';

import '../models/contact_trust.dart';
import 'local_settings_store.dart';

/// Locally saved per-contact trust levels — server has no contact book.
class ContactTrustStore {
  final _store = LocalSettingsStore();

  Future<TrustLevel> getTrust(String userId) async {
    final raw = await _store.getString('contact_trust_$userId', '');
    return TrustLevel.fromStorage(raw.isEmpty ? null : raw);
  }

  Future<void> setTrust(String userId, TrustLevel level) async {
    await _store.setString('contact_trust_$userId', level.storageKey);
  }

  Future<void> removeTrust(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('app_settings_contact_trust_$userId');
  }
}

/// Reads all saved trust levels on boot.
Future<Map<String, TrustLevel>> loadAllContactTrust() async {
  final prefs = await SharedPreferences.getInstance();
  const prefix = 'app_settings_contact_trust_';
  final result = <String, TrustLevel>{};
  for (final key in prefs.getKeys()) {
    if (key.startsWith(prefix)) {
      final userId = key.substring(prefix.length);
      final raw = prefs.getString(key);
      if (raw != null && raw.isNotEmpty) {
        result[userId] = TrustLevel.fromStorage(raw);
      }
    }
  }
  return result;
}
