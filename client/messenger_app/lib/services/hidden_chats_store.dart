import 'local_settings_store.dart';

enum HiddenChatSort { recent, name }

/// Registry and policies for secret-hidden server conversations + vault settings.
class HiddenChatsStore {
  HiddenChatsStore._();
  static final instance = HiddenChatsStore._();

  final _store = LocalSettingsStore();

  Future<Set<String>> loadSecretHiddenIds() async {
    final list = await _store.getStringList('hidden_secret_conversations');
    return list.toSet();
  }

  Future<void> saveSecretHiddenIds(Set<String> ids) async {
    await _store.setStringList('hidden_secret_conversations', ids.toList());
  }

  Future<void> addSecretHidden(String conversationId) async {
    final ids = await loadSecretHiddenIds();
    ids.add(conversationId);
    await saveSecretHiddenIds(ids);
  }

  Future<void> removeSecretHidden(String conversationId) async {
    final ids = await loadSecretHiddenIds();
    ids.remove(conversationId);
    await saveSecretHiddenIds(ids);
  }

  Future<bool> excludeFromGlobalSearch() => _store.getBool('hidden_exclude_search', true);

  Future<void> setExcludeFromGlobalSearch(bool v) => _store.setBool('hidden_exclude_search', v);

  Future<bool> silenceNotifications() => _store.getBool('hidden_silence_notif', true);

  Future<void> setSilenceNotifications(bool v) => _store.setBool('hidden_silence_notif', v);

  Future<HiddenChatSort> sortOrder() async {
    final raw = await _store.getString('hidden_sort_order', HiddenChatSort.recent.name);
    return HiddenChatSort.values.firstWhere((v) => v.name == raw, orElse: () => HiddenChatSort.recent);
  }

  Future<void> setSortOrder(HiddenChatSort order) => _store.setString('hidden_sort_order', order.name);

  Future<bool> gestureEntryEnabled() => _store.getBool('hidden_gesture_entry', true);

  Future<void> setGestureEntryEnabled(bool v) => _store.setBool('hidden_gesture_entry', v);

  /// Typed in main chat search to open hidden area (case-insensitive).
  Future<String> secretSearchCommand() => _store.getString('hidden_search_cmd', '.скрытые');

  Future<void> setSecretSearchCommand(String cmd) => _store.setString('hidden_search_cmd', cmd.trim());

  bool matchesSecretCommand(String query, String command) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return false;
    final cmd = command.trim().toLowerCase();
    return q == cmd || q == '.hidden' || q == '#скрытые' || q == '#hidden';
  }
}
