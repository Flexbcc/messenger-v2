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
    await _store.remove('contact_trust_$userId');
  }
}

/// Reads all saved trust levels on boot.
Future<Map<String, TrustLevel>> loadAllContactTrust() async {
  final entries = await LocalSettingsStore().getStringEntries('contact_trust_');
  return {
    for (final entry in entries.entries)
      if (entry.value.isNotEmpty)
        entry.key: TrustLevel.fromStorage(entry.value),
  };
}
