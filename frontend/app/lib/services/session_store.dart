import 'package:shared_preferences/shared_preferences.dart';

/// Persisted local session — not OS-keychain-grade secure storage (MVP
/// simplification, see ADR-0005). The actual key material lives in
/// crypto/crypto_service.dart and crypto/auth_keypair.dart, not here.
class SessionStore {
  static const _userIdKey = 'session_user_id';
  static const _deviceIdKey = 'session_device_id';
  static const _tokenKey = 'session_access_token';
  static const _displayNameKey = 'session_display_name';
  static const _rememberedUserIdKey = 'identity_user_id';
  static const _rememberedDeviceIdKey = 'identity_device_id';
  static const _rememberedDisplayNameKey = 'identity_display_name';

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
    // Account locator is not a secret. Keep it after logout so the retained
    // private key can authenticate this same device by challenge-response.
    await prefs.setString(_rememberedUserIdKey, userId);
    await prefs.setString(_rememberedDeviceIdKey, deviceId);
    await prefs.setString(_rememberedDisplayNameKey, displayName);
  }

  Future<void> saveToken(String accessToken) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, accessToken);
  }

  Future<void> saveDisplayName(String displayName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_displayNameKey, displayName);
    await prefs.setString(_rememberedDisplayNameKey, displayName);
  }

  Future<RememberedIdentity?> loadRememberedIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_rememberedUserIdKey);
    final deviceId = prefs.getString(_rememberedDeviceIdKey);
    final displayName = prefs.getString(_rememberedDisplayNameKey);
    if (userId == null || deviceId == null || displayName == null) return null;
    return RememberedIdentity(
      userId: userId,
      deviceId: deviceId,
      displayName: displayName,
    );
  }

  Future<void> rememberIdentity({
    required String userId,
    required String deviceId,
    required String displayName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_rememberedUserIdKey, userId);
    await prefs.setString(_rememberedDeviceIdKey, deviceId);
    await prefs.setString(_rememberedDisplayNameKey, displayName);
  }

  Future<Session?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_userIdKey);
    final deviceId = prefs.getString(_deviceIdKey);
    final token = prefs.getString(_tokenKey);
    final displayName = prefs.getString(_displayNameKey);
    if (userId == null ||
        deviceId == null ||
        token == null ||
        displayName == null) {
      return null;
    }
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
    await prefs.remove(_tokenKey);
    await prefs.remove(_displayNameKey);
  }

  /// Forget the account locator too. Used only by explicit profile deletion;
  /// normal logout intentionally keeps it for key-based sign-in.
  Future<void> forgetIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_rememberedUserIdKey);
    await prefs.remove(_rememberedDeviceIdKey);
    await prefs.remove(_rememberedDisplayNameKey);
  }
}

class RememberedIdentity {
  const RememberedIdentity({
    required this.userId,
    required this.deviceId,
    required this.displayName,
  });

  final String userId;
  final String deviceId;
  final String displayName;
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
