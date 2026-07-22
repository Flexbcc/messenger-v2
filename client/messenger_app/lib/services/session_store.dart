import 'package:shared_preferences/shared_preferences.dart';

import '../security/secure_prefs.dart';

/// Persisted local session.
///
/// Security split (see ADR-0005 update):
/// - userId, deviceId, displayName → SharedPreferences (not sensitive)
/// - accessToken → SecurePrefs / OS keychain (EncryptedSharedPrefs on Android)
///
/// Migration: on first read, if token is found in SharedPreferences from the
/// old storage, it is moved to secure storage and removed from prefs.
class SessionStore {
  static const _userIdKey = 'session_user_id';
  static const _deviceIdKey = 'session_device_id';
  static const _displayNameKey = 'session_display_name';

  // Secure storage key for JWT token
  static const _secureTokenKey = 'session_access_token_secure';
  // Legacy prefs key (for migration)
  static const _legacyTokenKey = 'session_access_token';

  final _secure = SecurePrefs.instance;

  Future<void> save({
    required String userId,
    required String deviceId,
    required String accessToken,
    required String displayName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userIdKey, userId);
    await prefs.setString(_deviceIdKey, deviceId);
    await prefs.setString(_displayNameKey, displayName);
    await _secure.write(_secureTokenKey, accessToken);
    // Remove legacy plain-text token if present
    await prefs.remove(_legacyTokenKey);
  }

  Future<void> saveToken(String accessToken) async {
    await _secure.write(_secureTokenKey, accessToken);
    // Remove legacy plain-text token if present
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_legacyTokenKey);
  }

  Future<void> saveDisplayName(String displayName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_displayNameKey, displayName);
  }

  Future<Session?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_userIdKey);
    final deviceId = prefs.getString(_deviceIdKey);
    final displayName = prefs.getString(_displayNameKey);

    if (userId == null || deviceId == null || displayName == null) {
      return null;
    }

    // Try secure storage first
    String? token = await _secure.read(_secureTokenKey);

    // Migration: move legacy plain-text token to secure storage
    if (token == null) {
      final legacyToken = prefs.getString(_legacyTokenKey);
      if (legacyToken != null) {
        token = legacyToken;
        await _secure.write(_secureTokenKey, legacyToken);
        await prefs.remove(_legacyTokenKey);
      }
    }

    if (token == null) return null;

    return Session(
      userId: userId,
      deviceId: deviceId,
      accessToken: token,
      displayName: displayName,
    );
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userIdKey);
    await prefs.remove(_deviceIdKey);
    await prefs.remove(_displayNameKey);
    await prefs.remove(_legacyTokenKey);
    await _secure.remove(_secureTokenKey);
  }
}

class Session {
  Session({
    required this.userId,
    required this.deviceId,
    required this.accessToken,
    required this.displayName,
  });

  final String userId;
  final String deviceId;
  String accessToken;
  String displayName;
}
