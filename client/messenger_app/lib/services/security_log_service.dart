import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local security event log — mock store, replaceable with API later.
class SecurityLogService {
  SecurityLogService._();
  static final instance = SecurityLogService._();

  static const _key = 'security_log_v2';
  static const _maxEvents = 100;

  Future<List<SecurityEvent>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    return raw.map(SecurityEvent.decode).whereType<SecurityEvent>().toList();
  }

  Future<void> append(SecurityEvent event) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? [];
    list.insert(0, event.encode());
    while (list.length > _maxEvents) {
      list.removeLast();
    }
    await prefs.setStringList(_key, list);
    debugPrint('SecurityLog: ${event.title}');
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

class SecurityEvent {
  SecurityEvent({required this.title, required this.subtitle, required this.at, this.icon = 'shield'});

  final String title;
  final String subtitle;
  final DateTime at;
  final String icon;

  /// JSON encoding — safe with any characters in title/subtitle.
  String encode() => jsonEncode({
        'at': at.toIso8601String(),
        'icon': icon,
        'title': title,
        'subtitle': subtitle,
      });

  static SecurityEvent? decode(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return SecurityEvent(
        at: DateTime.tryParse(m['at'] as String? ?? '') ?? DateTime.now(),
        icon: m['icon'] as String? ?? 'shield',
        title: m['title'] as String? ?? '',
        subtitle: m['subtitle'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}
