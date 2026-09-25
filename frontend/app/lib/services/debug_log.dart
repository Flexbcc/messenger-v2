import 'package:flutter/foundation.dart';

/// In-memory ring buffer for diagnosing API/crypto issues during local testing.
class DebugLog {
  DebugLog._();
  static final instance = DebugLog._();

  static const _max = 80;
  static const _maxMessageCharacters = 2048;
  final List<String> _lines = [];

  List<String> get lines => List.unmodifiable(_lines.reversed);

  void info(String tag, String message) => _add('INFO', tag, message);
  void warn(String tag, String message, [Object? err]) {
    final extra = err != null ? ' | $err' : '';
    _add('WARN', tag, '$message$extra');
  }

  void error(String tag, String message, [Object? err]) {
    final extra = err != null ? ' | $err' : '';
    _add('ERR', tag, '$message$extra');
  }

  void _add(String level, String tag, String message) {
    final safeTag = redact(tag, maximum: 48);
    final safeMessage = redact(message, maximum: _maxMessageCharacters);
    final line =
        '${DateTime.now().toIso8601String().substring(11, 19)} [$level] $safeTag: $safeMessage';
    _lines.add(line);
    if (_lines.length > _max) _lines.removeAt(0);
    if (kDebugMode) debugPrint(line);
  }

  static String redact(String value, {int maximum = _maxMessageCharacters}) {
    var sanitized = value.replaceAll(RegExp(r'[\r\n\t]'), ' ');
    sanitized = sanitized.replaceAll(
      RegExp(r'Bearer\s+[A-Za-z0-9._~-]+', caseSensitive: false),
      'Bearer [REDACTED]',
    );
    sanitized = sanitized.replaceAll(
      RegExp(r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b'),
      '[REDACTED_JWT]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'([?&](?:access_token|token|secret|code)=)[^&#\s]+',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}[REDACTED]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'''(["']?(?:access_token|refresh_token|token|secret|password|authorization)["']?\s*[:=]\s*)["']?[^"',}\s]+''',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}[REDACTED]',
    );
    if (sanitized.length > maximum) {
      return '${sanitized.substring(0, maximum)}…';
    }
    return sanitized;
  }

  void clear() => _lines.clear();

  /// Most recent error line, if any.
  String? get lastError {
    for (var i = _lines.length - 1; i >= 0; i--) {
      if (_lines[i].contains('[ERR]')) return _lines[i];
    }
    return null;
  }
}
