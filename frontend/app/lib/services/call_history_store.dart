import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/call_history_entry.dart';

/// Local call log — persisted on this device only (no server API yet).
class CallHistoryStore {
  static const _key = 'app_settings_call_history_v1';
  static const _maxEntries = 200;

  Future<List<CallHistoryEntry>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => CallHistoryEntry.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> append(CallHistoryEntry entry) async {
    final all = await loadAll();
    all.insert(0, entry);
    if (all.length > _maxEntries) {
      all.removeRange(_maxEntries, all.length);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(all.map((e) => e.toJson()).toList()));
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
