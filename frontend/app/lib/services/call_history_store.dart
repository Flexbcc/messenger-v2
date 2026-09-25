import 'dart:convert';

import '../models/call_history_entry.dart';
import 'local_settings_store.dart';

/// Local call log — persisted on this device only (no server API yet).
class CallHistoryStore {
  static const _key = 'call_history_v1';
  static const _maxEntries = 200;
  final _store = LocalSettingsStore();

  Future<List<CallHistoryEntry>> loadAll() async {
    final raw = await _store.getString(_key, '');
    if (raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => CallHistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<CallHistoryEntry>> append(CallHistoryEntry entry) async {
    final all = await loadAll();
    all.insert(0, entry);
    if (all.length > _maxEntries) {
      all.removeRange(_maxEntries, all.length);
    }
    await _store.setString(
      _key,
      jsonEncode(all.map((e) => e.toJson()).toList()),
    );
    return all;
  }

  Future<void> clear() async {
    await _store.remove(_key);
  }
}
