import 'package:shared_preferences/shared_preferences.dart';

import 'account_scope_id.dart';

/// Real local persistence for UI settings. Prefixed keys avoid collisions
/// with [SessionStore]. When [activeUserId] is set, keys are namespaced
/// per account (`app_settings_u_<id>_…`).
class LocalSettingsStore {
  static const _prefix = 'app_settings_';

  static String? _activeUserId;

  static String? get activeUserId => _activeUserId;

  static void setActiveUser(String? userId) {
    _activeUserId = AccountScopeId.validateNullable(userId);
  }

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  String _physical(String key) {
    final uid = _activeUserId;
    if (uid == null) return '$_prefix$key';
    return '${_prefix}u_${uid}_$key';
  }

  Future<void> setBool(String key, bool value) async {
    if (!await (await _prefs).setBool(_physical(key), value)) {
      throw StateError('Unable to persist local boolean setting');
    }
  }

  Future<bool> getBool(String key, bool fallback) async =>
      (await _prefs).getBool(_physical(key)) ?? fallback;

  Future<void> setString(String key, String value) async {
    if (!await (await _prefs).setString(_physical(key), value)) {
      throw StateError('Unable to persist local string setting');
    }
  }

  Future<String> getString(String key, String fallback) async =>
      (await _prefs).getString(_physical(key)) ?? fallback;

  Future<void> setInt(String key, int value) async {
    if (!await (await _prefs).setInt(_physical(key), value)) {
      throw StateError('Unable to persist local integer setting');
    }
  }

  Future<int> getInt(String key, int fallback) async =>
      (await _prefs).getInt(_physical(key)) ?? fallback;

  Future<void> setStringList(String key, List<String> value) async {
    if (!await (await _prefs).setStringList(_physical(key), value)) {
      throw StateError('Unable to persist local string-list setting');
    }
  }

  Future<List<String>> getStringList(String key) async =>
      (await _prefs).getStringList(_physical(key)) ?? [];

  Future<void> remove(String key) async {
    final prefs = await _prefs;
    final physical = _physical(key);
    if (prefs.containsKey(physical) && !await prefs.remove(physical)) {
      throw StateError('Unable to remove local setting');
    }
  }

  /// Reads string entries below a logical prefix within the active account.
  Future<Map<String, String>> getStringEntries(String logicalPrefix) async {
    final prefs = await _prefs;
    final physicalPrefix = _physical(logicalPrefix);
    final result = <String, String>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(physicalPrefix)) continue;
      final value = prefs.getString(key);
      if (value != null) {
        result[key.substring(physicalPrefix.length)] = value;
      }
    }
    return result;
  }

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
          rest.startsWith('contact_alias_') ||
          rest.startsWith('contact_trust_') ||
          rest.startsWith('device_profile_') ||
          rest == 'call_history_v1' ||
          rest == 'security_log_v1' ||
          rest == 'security_log_v2' ||
          rest == 'duress_runtime_packed_v1' ||
          rest == 'duress_policy.v1' ||
          rest == 'hidden_vault.v1' ||
          rest == 'hidden_conversations' ||
          rest.startsWith('notif_') ||
          rest == 'theme_mode';
    });
  }

  static Future<int> _removeMatching(bool Function(String key) test) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where(test).toList();
    for (final k in keys) {
      if (!await prefs.remove(k)) {
        throw StateError('Unable to remove scoped local setting');
      }
    }
    return keys.length;
  }
}
