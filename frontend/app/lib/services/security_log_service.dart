import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local security event log — mock store, replaceable with API later.
class SecurityLogService {
  SecurityLogService._();
  static final instance = SecurityLogService._();

  static const _key = 'security_log_v1';
  static const _maxEvents = 100;

  Future<List<SecurityEvent>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    return raw.map(SecurityEvent.decode).toList();
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
  SecurityEvent({
    required this.title,
    required this.subtitle,
    required this.at,
    this.icon = 'shield',
  });

  final String title;
  final String subtitle;
  final DateTime at;
  final String icon;

  String encode() => '${at.toIso8601String()}|$icon|$title|$subtitle';

  static SecurityEvent decode(String raw) {
    final parts = raw.split('|');
    if (parts.length < 4) {
      return SecurityEvent(title: raw, subtitle: '', at: DateTime.now());
    }
    return SecurityEvent(
      at: DateTime.tryParse(parts[0]) ?? DateTime.now(),
      icon: parts[1],
      title: parts[2],
      subtitle: parts.sublist(3).join('|'),
    );
  }
}
