import 'local_settings_store.dart';

/// Contacts notified on decoy-PIN duress signals (local list, client-only).
class TrustedContactsStore {
  TrustedContactsStore._();
  static final instance = TrustedContactsStore._();

  static const _key = 'trusted_contact_user_ids';
  final _store = LocalSettingsStore();

  Future<List<String>> load() => _store.getStringList(_key);

  Future<void> save(List<String> userIds) async {
    final unique = userIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    await _store.setStringList(_key, unique);
  }

  Future<void> add(String userId) async {
    final ids = await load();
    if (ids.contains(userId)) return;
    ids.add(userId);
    await save(ids);
  }

  Future<void> remove(String userId) async {
    final ids = await load();
    ids.remove(userId);
    await save(ids);
  }
}
