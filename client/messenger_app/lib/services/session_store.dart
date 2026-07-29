import 'package:shared_preferences/shared_preferences.dart';

/// Persisted local session — not OS-keychain-grade secure storage (MVP
/// simplification, see ADR-0005). The actual key material lives in
/// crypto/crypto_service.dart and crypto/auth_keypair.dart, not here.
class SessionStore {
  static const _userIdKey = 'session_user_id';
  static const _deviceIdKey = 'session_device_id';
  static const _tokenKey = 'session_access_token';
  static const _displayNameKey = 'session_display_name';

  Future<void> save({
    required String userId,
    required String deviceId,
    required String accessToken,
    required String displayName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userIdKey, userId);
    await prefs.setString(_deviceIdKey, deviceId);
    await prefs.setString(_tokenKey, accessToken);
    await prefs.setString(_displayNameKey, displayName);
  }

  Future<void> saveToken(String accessToken) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, accessToken);
  }

  Future<void> saveDisplayName(String displayName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_displayNameKey, displayName);
  }

  Future<Session?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_userIdKey);
    final deviceId = prefs.getString(_deviceIdKey);
    final token = prefs.getString(_tokenKey);
    final displayName = prefs.getString(_displayNameKey);
    if (userId == null || deviceId == null || token == null || displayName == null) {
      return null;
    }
    return Session(userId: userId, deviceId: deviceId, accessToken: token, displayName: displayName);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userIdKey);
    await prefs.remove(_deviceIdKey);
    await prefs.remove(_tokenKey);
    await prefs.remove(_displayNameKey);
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
