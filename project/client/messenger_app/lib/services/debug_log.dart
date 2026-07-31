import 'package:flutter/foundation.dart';

/// In-memory ring buffer for diagnosing API/crypto issues during local testing.
class DebugLog {
  DebugLog._();
  static final instance = DebugLog._();

  static const _max = 80;
  final List<String> _lines = [];

  List<String> get lines => List.unmodifiable(_lines.reversed);

  void info(String tag, String message) => _add('INFO', tag, message);
  void warn(String tag, String message) => _add('WARN', tag, message);
  void error(String tag, String message, [Object? err]) {
    final extra = err != null ? ' | $err' : '';
    _add('ERR', tag, '$message$extra');
  }

  void _add(String level, String tag, String message) {
    final line = '${DateTime.now().toIso8601String().substring(11, 19)} [$level] $tag: $message';
    _lines.add(line);
    if (_lines.length > _max) _lines.removeAt(0);
    debugPrint(line);
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
