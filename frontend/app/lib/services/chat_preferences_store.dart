import 'local_settings_store.dart';

/// Per-chat settings persisted locally on this device only.
class ChatPreferencesStore {
  final _store = LocalSettingsStore();

  Future<DateTime?> getLastRead(String conversationId) async {
    final ms = await _store.getInt('chat_last_read_ms_$conversationId', 0);
    if (ms == 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> setLastRead(String conversationId, DateTime time) async {
    await _store.setInt(
      'chat_last_read_ms_$conversationId',
      time.millisecondsSinceEpoch,
    );
  }

  Future<bool> isMuted(String conversationId) async =>
      _store.getBool('chat_mute_$conversationId', false);

  Future<void> setMuted(String conversationId, bool muted) async {
    await _store.setBool('chat_mute_$conversationId', muted);
  }

  /// Null = off. Otherwise messages older than this many seconds are hidden locally.
  Future<int?> getDisappearingSeconds(String conversationId) async {
    final seconds = await _store.getInt(
      'chat_disappear_sec_$conversationId',
      0,
    );
    return seconds == 0 ? null : seconds;
  }

  Future<void> setDisappearingSeconds(
    String conversationId,
    int? seconds,
  ) async {
    await _store.setInt('chat_disappear_sec_$conversationId', seconds ?? 0);
  }
}
