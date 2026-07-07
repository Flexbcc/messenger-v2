import 'package:shared_preferences/shared_preferences.dart';

/// Real local persistence for UI-only settings (Notifications, Data &
/// Storage, Appearance). No backend sync yet — see NEXT_TASK.md. Prefixed
/// keys to avoid collisions with session_store.dart.
class LocalSettingsStore {
  static const _prefix = 'app_settings_';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<void> setBool(String key, bool value) async => (await _prefs).setBool('$_prefix$key', value);
  Future<bool> getBool(String key, bool fallback) async => (await _prefs).getBool('$_prefix$key') ?? fallback;

  Future<void> setString(String key, String value) async => (await _prefs).setString('$_prefix$key', value);
  Future<String> getString(String key, String fallback) async => (await _prefs).getString('$_prefix$key') ?? fallback;

  Future<void> setInt(String key, int value) async => (await _prefs).setInt('$_prefix$key', value);
  Future<int> getInt(String key, int fallback) async => (await _prefs).getInt('$_prefix$key') ?? fallback;

  Future<void> setStringList(String key, List<String> value) async =>
      (await _prefs).setStringList('$_prefix$key', value);
  Future<List<String>> getStringList(String key) async => (await _prefs).getStringList('$_prefix$key') ?? [];
}
