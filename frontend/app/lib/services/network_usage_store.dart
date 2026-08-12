import 'local_settings_store.dart';

/// Tracks bytes sent/received over the last 30 days (design.md §14).
class NetworkUsageStore {
  final _store = LocalSettingsStore();

  static const _sentKey = 'net_sent_bytes';
  static const _receivedKey = 'net_received_bytes';
  static const _periodStartKey = 'net_period_start';

  Future<({int sent, int received})> getTotals() async {
    await _rollPeriodIfNeeded();
    final sent = await _store.getInt(_sentKey, 0);
    final received = await _store.getInt(_receivedKey, 0);
    return (sent: sent, received: received);
  }

  Future<void> recordSent(int bytes) async {
    if (bytes <= 0) return;
    await _rollPeriodIfNeeded();
    final current = await _store.getInt(_sentKey, 0);
    await _store.setInt(_sentKey, current + bytes);
  }

  Future<void> recordReceived(int bytes) async {
    if (bytes <= 0) return;
    await _rollPeriodIfNeeded();
    final current = await _store.getInt(_receivedKey, 0);
    await _store.setInt(_receivedKey, current + bytes);
  }

  Future<void> _rollPeriodIfNeeded() async {
    final startMs = await _store.getInt(_periodStartKey, 0);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (startMs == 0 ||
        now - startMs > const Duration(days: 30).inMilliseconds) {
      await _store.setInt(_periodStartKey, now);
      await _store.setInt(_sentKey, 0);
      await _store.setInt(_receivedKey, 0);
    }
  }
}
