import 'package:flutter/foundation.dart';

import 'local_settings_store.dart';

/// Client-side relay rate limit — spec/0404 open questions.
/// Also exposes PIN-attempt delay labels used by unlock UI / catalog read-only.
class DuressRateLimiter {
  DuressRateLimiter._();
  static final instance = DuressRateLimiter._();

  static const maxPerHour = 30;
  static const _windowMs = 3600000;
  static const _key = 'duress_relay_timestamps_v1';

  final _store = LocalSettingsStore();

  /// Delay before next unlock attempt for [failCount] wrong PINs.
  static Duration lockoutForAttempt(int failCount) {
    return switch (failCount) {
      <= 2 => Duration.zero,
      3 => const Duration(seconds: 30),
      4 => const Duration(minutes: 2),
      5 => const Duration(minutes: 10),
      6 => const Duration(minutes: 30),
      7 => const Duration(hours: 2),
      8 => const Duration(hours: 12),
      9 => const Duration(hours: 24),
      _ => const Duration(hours: 24),
    };
  }

  static String policyLabel({
    required bool wipeEnabled,
    String wipeAfter = '5',
  }) {
    if (wipeEnabled) {
      return '1–2: предупреждение · 3+: задержка · $wipeAfter: стирание';
    }
    return '1–2: предупреждение; 3: 30с; 4: 2м; 5: 10м; 6: 30м; 7: 2ч; 8: 12ч; 9: 24ч; 10: блокировка';
  }

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
