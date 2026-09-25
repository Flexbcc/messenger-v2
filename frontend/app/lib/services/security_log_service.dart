import 'dart:convert';

import '../security/device_crypto.dart';
import 'local_settings_store.dart';

/// Bounded local security event log.
class SecurityLogService {
  SecurityLogService._();
  static final instance = SecurityLogService._();

  static const _key = 'security_log_v2';
  static const _legacyKey = 'security_log_v1';
  static const _maxEvents = 100;
  static const _encryptedPrefix = 'enc:v1:';
  final _store = LocalSettingsStore();
  Future<void> _operation = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _operation.then((_) => action());
    _operation = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<List<SecurityEvent>> load() => _serial(_load);

  Future<List<SecurityEvent>> _load() async {
    final stored = await _store.getString(_key, '');
    if (stored.isNotEmpty) return _decodeEncrypted(stored);

    final legacy = await _readLegacy();
    if (legacy.isEmpty) return const [];
    final decoded = _decodeEvents(legacy);
    await _save(decoded.map((event) => event.encode()).toList());
    await _store.remove(_legacyKey);
    return decoded;
  }

  Future<List<String>> _readLegacy() async {
    try {
      final stored = await _store.getString(_legacyKey, '');
      if (stored.isNotEmpty) {
        return (await _decodeEncrypted(
          stored,
        )).map((event) => event.encode()).toList();
      }
    } on TypeError {
      // Version 0 used a string-list under the same preference key.
    }
    return _store.getStringList(_legacyKey);
  }

  Future<List<SecurityEvent>> _decodeEncrypted(String stored) async {
    if (!stored.startsWith(_encryptedPrefix)) {
      throw const FormatException('invalid security log envelope');
    }
    final clear = await DeviceCrypto.instance.decryptJson(
      stored.substring(_encryptedPrefix.length),
    );
    if (clear == null) {
      throw StateError('Security log authentication failed');
    }
    final events = clear['events'];
    if (events is! List || events.length > _maxEvents) {
      throw const FormatException('invalid security log payload');
    }
    if (events.any((event) => event is! String)) {
      throw const FormatException('invalid security log event');
    }
    return _decodeEvents(events.cast<String>());
  }

  List<SecurityEvent> _decodeEvents(List<String> raw) {
    if (raw.length > _maxEvents) {
      throw const FormatException('security log exceeds event limit');
    }
    final decoded = <SecurityEvent>[];
    for (final item in raw) {
      final event = SecurityEvent.tryDecode(item);
      if (event == null) {
        throw const FormatException('invalid security log event');
      }
      decoded.add(event);
    }
    return decoded;
  }

  Future<void> append(SecurityEvent event) => _serial(() async {
    final current = await _load();
    final list = current.map((event) => event.encode()).toList();
    list.insert(0, event.encode());
    if (list.length > _maxEvents) list.removeRange(_maxEvents, list.length);
    await _save(list);
  });

  Future<void> clear() => _serial(() async {
    await _store.remove(_key);
    await _store.remove(_legacyKey);
  });

  Future<void> _save(List<String> events) async {
    final encrypted = await DeviceCrypto.instance.encryptJson({
      'events': events,
    });
    await _store.setString(_key, '$_encryptedPrefix$encrypted');
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

  String encode() => jsonEncode({
    'v': 1,
    'at': at.toUtc().toIso8601String(),
    'icon': _bounded(icon, 64),
    'title': _bounded(title, 256),
    'subtitle': _bounded(subtitle, 1024),
  });

  static SecurityEvent? tryDecode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final at = DateTime.tryParse(decoded['at']?.toString() ?? '');
        final title = decoded['title']?.toString();
        final subtitle = decoded['subtitle']?.toString() ?? '';
        final icon = decoded['icon']?.toString() ?? 'shield';
        if (at == null ||
            title == null ||
            title.isEmpty ||
            title.length > 256 ||
            subtitle.length > 1024 ||
            icon.length > 64) {
          return null;
        }
        return SecurityEvent(
          at: at.toLocal(),
          icon: icon,
          title: title,
          subtitle: subtitle,
        );
      }
    } on FormatException {
      // Fall through to the v0 delimiter migration below.
    }

    // Read-only migration for entries written before the JSON format.
    final parts = raw.split('|');
    if (parts.length < 4) return null;
    final at = DateTime.tryParse(parts[0]);
    final subtitle = parts.sublist(3).join('|');
    if (at == null ||
        parts[1].length > 64 ||
        parts[2].isEmpty ||
        parts[2].length > 256 ||
        subtitle.length > 1024) {
      return null;
    }
    return SecurityEvent(
      at: at,
      icon: parts[1],
      title: parts[2],
      subtitle: subtitle,
    );
  }

  static String _bounded(String value, int maxCodeUnits) =>
      value.length <= maxCodeUnits ? value : value.substring(0, maxCodeUnits);
}
