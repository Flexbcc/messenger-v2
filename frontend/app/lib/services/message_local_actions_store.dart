import 'local_settings_store.dart';

/// Per-user local-only message actions (hide, pin) — not synced to server.
class MessageLocalActionsStore {
  MessageLocalActionsStore._();
  static final instance = MessageLocalActionsStore._();

  final _store = LocalSettingsStore();

  String _hiddenKey(String userId) => 'hidden_messages_$userId';
  String _pinnedKey(String userId) => 'pinned_messages_$userId';

  Future<List<String>> loadHidden(String userId) =>
      _store.getStringList(_hiddenKey(userId));

  Future<List<String>> loadPinned(String userId) =>
      _store.getStringList(_pinnedKey(userId));

  Future<void> hideMessage(String userId, String messageId) async {
    final ids = await loadHidden(userId);
    if (!ids.contains(messageId)) {
      await _store.setStringList(_hiddenKey(userId), [...ids, messageId]);
    }
  }

  Future<void> setPinned(String userId, String messageId, bool pinned) async {
    final ids = await loadPinned(userId);
    if (pinned) {
      if (!ids.contains(messageId)) {
        await _store.setStringList(_pinnedKey(userId), [...ids, messageId]);
      }
    } else {
      await _store.setStringList(
        _pinnedKey(userId),
        ids.where((id) => id != messageId).toList(),
      );
    }
  }
}
