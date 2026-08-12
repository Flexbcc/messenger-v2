import 'package:shared_preferences/shared_preferences.dart';

/// Real local persistence for UI settings. Prefixed keys avoid collisions
/// with [SessionStore]. When [activeUserId] is set, keys are namespaced
/// per account (`app_settings_u_<id>_…`).
class LocalSettingsStore {
  static const _prefix = 'app_settings_';

  static String? _activeUserId;

  static String? get activeUserId => _activeUserId;

  static void setActiveUser(String? userId) {
    _activeUserId = (userId == null || userId.isEmpty) ? null : userId;
  }

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  String _physical(String key) {
    final uid = _activeUserId;
    if (uid == null) return '$_prefix$key';
    return '${_prefix}u_${uid}_$key';
  }

  Future<void> setBool(String key, bool value) async =>
      (await _prefs).setBool(_physical(key), value);
  Future<bool> getBool(String key, bool fallback) async =>
      (await _prefs).getBool(_physical(key)) ?? fallback;

  Future<void> setString(String key, String value) async =>
      (await _prefs).setString(_physical(key), value);
  Future<String> getString(String key, String fallback) async =>
      (await _prefs).getString(_physical(key)) ?? fallback;

  Future<void> setInt(String key, int value) async =>
      (await _prefs).setInt(_physical(key), value);
  Future<int> getInt(String key, int fallback) async =>
      (await _prefs).getInt(_physical(key)) ?? fallback;

  Future<void> setStringList(String key, List<String> value) async =>
      (await _prefs).setStringList(_physical(key), value);
  Future<List<String>> getStringList(String key) async =>
      (await _prefs).getStringList(_physical(key)) ?? [];

  Future<void> remove(String key) async =>
      (await _prefs).remove(_physical(key));

  /// Wipe all prefs for the currently active user namespace.
  static Future<int> clearActiveUserData() async {
    final uid = _activeUserId;
    if (uid == null) return 0;
    return _removeMatching((k) => k.startsWith('${_prefix}u_${uid}_'));
  }

  /// Remove legacy unscoped account settings (catalog / privacy / seed).
  /// Device-global keys that are not account-bound are left alone.
  static Future<int> clearUnscopedAccountData() async {
    return _removeMatching((k) {
      if (!k.startsWith(_prefix)) return false;
      if (k.startsWith('${_prefix}u_')) return false; // other accounts
      final rest = k.substring(_prefix.length);
      return rest.startsWith('catalog.') ||
          rest.startsWith('pm_') ||
          rest == 'hidden_conversations' ||
          rest.startsWith('notif_') ||
          rest == 'theme_mode';
    });
  }

  static Future<int> _removeMatching(bool Function(String key) test) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where(test).toList();
    for (final k in keys) {
      await prefs.remove(k);
    }
    return keys.length;
  }
}
