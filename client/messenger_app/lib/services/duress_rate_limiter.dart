import 'package:flutter/foundation.dart';

import 'local_settings_store.dart';

/// Client-side relay rate limit — spec/0404 open questions.
class DuressRateLimiter {
  DuressRateLimiter._();
  static final instance = DuressRateLimiter._();

  static const maxPerHour = 30;
  static const _windowMs = 3600000;
  static const _key = 'duress_relay_timestamps_v1';

  final _store = LocalSettingsStore();

  Future<bool> allowRelay() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final raw = await _store.getString(_key, '');
    final kept = raw
        .split(',')
        .where((e) => e.isNotEmpty)
        .map(int.tryParse)
        .whereType<int>()
        .where((t) => now - t < _windowMs)
        .toList();
    if (kept.length >= maxPerHour) {
      debugPrint('DuressRateLimiter: relay blocked ($maxPerHour/h)');
      return false;
    }
    kept.add(now);
    await _store.setString(_key, kept.join(','));
    return true;
  }
}
