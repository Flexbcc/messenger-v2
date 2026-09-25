import 'catalog_sync.dart';
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
    await CatalogSync.syncHidden();
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

  Future<bool> excludeFromGlobalSearch() =>
      _store.getBool('hidden_exclude_search', true);

  Future<void> setExcludeFromGlobalSearch(bool v) async {
    await _store.setBool('hidden_exclude_search', v);
    await CatalogSync.syncHidden();
  }

  Future<bool> silenceNotifications() =>
      _store.getBool('hidden_silence_notif', true);

  Future<void> setSilenceNotifications(bool v) async {
    await _store.setBool('hidden_silence_notif', v);
    await CatalogSync.syncHidden();
  }

  Future<bool> hideMediaFromGallery() =>
      _store.getBool('hidden_hide_media', true);

  Future<void> setHideMediaFromGallery(bool v) async {
    await _store.setBool('hidden_hide_media', v);
    await CatalogSync.syncHidden();
  }

  /// Catalog `hidden.open_method`: pin | gesture | secret_command
  Future<String> openMethod() => _store.getString('hidden_open_method', 'pin');

  Future<void> setOpenMethod(String method) async {
    await _store.setString('hidden_open_method', method);
    await CatalogSync.syncHidden();
  }

  /// Catalog `hidden.autolock` token.
  Future<String> autolock() => _store.getString('hidden_autolock', '1m');

  Future<void> setAutolock(String token) async {
    await _store.setString('hidden_autolock', token);
    await CatalogSync.syncHidden();
  }

  Future<Duration> autolockDuration() async {
    return switch (await autolock()) {
      'immediately' => Duration.zero,
      '30s' => const Duration(seconds: 30),
      '5m' => const Duration(minutes: 5),
      '15m' => const Duration(minutes: 15),
      _ => const Duration(minutes: 1),
    };
  }

  Future<HiddenChatSort> sortOrder() async {
    final raw = await _store.getString(
      'hidden_sort_order',
      HiddenChatSort.recent.name,
    );
    return HiddenChatSort.values.firstWhere(
      (v) => v.name == raw,
      orElse: () => HiddenChatSort.recent,
    );
  }

  Future<void> setSortOrder(HiddenChatSort order) =>
      _store.setString('hidden_sort_order', order.name);

  Future<bool> gestureEntryEnabled() =>
      _store.getBool('hidden_gesture_entry', false);

  Future<void> setGestureEntryEnabled(bool v) =>
      _store.setBool('hidden_gesture_entry', v);

  /// Typed in main chat search to open hidden area (case-insensitive).
  Future<String> secretSearchCommand() =>
      _store.getString('hidden_search_cmd', '.скрытые');

  Future<void> setSecretSearchCommand(String cmd) =>
      _store.setString('hidden_search_cmd', cmd.trim());

  bool matchesSecretCommand(String query, String command) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return false;
    final cmd = command.trim().toLowerCase();
    return q == cmd || q == '.hidden' || q == '#скрытые' || q == '#hidden';
  }
}
