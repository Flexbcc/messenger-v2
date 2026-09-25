import 'package:shared_preferences/shared_preferences.dart';

import '../security/secure_prefs.dart';

/// Persisted local session. The bearer token is kept in platform secure
/// storage; non-secret account locators remain in SharedPreferences.
class SessionStore {
  SessionStore({SessionSecretStore? secrets})
    : _secrets = secrets ?? const PlatformSessionSecretStore();

  final SessionSecretStore _secrets;

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
    Session(
      userId: userId,
      deviceId: deviceId,
      accessToken: accessToken,
      displayName: displayName,
    );
    // Never let metadata for a new login coexist with a credential from an
    // older account if persistence fails halfway through.
    await _secrets.remove(_tokenKey);
    final prefs = await SharedPreferences.getInstance();
    await _writeString(prefs, _userIdKey, userId);
    await _writeString(prefs, _deviceIdKey, deviceId);
    await _writeString(prefs, _displayNameKey, displayName);
    // Account locator is not a secret. Keep it after logout so the retained
    // private key can authenticate this same device by challenge-response.
    await _writeString(prefs, _rememberedUserIdKey, userId);
    await _writeString(prefs, _rememberedDeviceIdKey, deviceId);
    await _writeString(prefs, _rememberedDisplayNameKey, displayName);
    // Commit the bearer credential last. Partially written non-secret
    // locators cannot authenticate, while a token without complete metadata
    // could otherwise survive a failed save and be recovered unexpectedly.
    await _secrets.write(_tokenKey, accessToken);
  }

  Future<void> saveToken(String accessToken) async {
    _validateSessionText(accessToken, 'accessToken', 8192, minLength: 32);
    await _secrets.write(_tokenKey, accessToken);
  }

  Future<void> saveDisplayName(String displayName) async {
    _validateSessionText(displayName, 'displayName', 120);
    final prefs = await SharedPreferences.getInstance();
    await _writeString(prefs, _displayNameKey, displayName);
    await _writeString(prefs, _rememberedDisplayNameKey, displayName);
  }

  Future<RememberedIdentity?> loadRememberedIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_rememberedUserIdKey);
    final deviceId = prefs.getString(_rememberedDeviceIdKey);
    final displayName = prefs.getString(_rememberedDisplayNameKey);
    if (userId == null || deviceId == null || displayName == null) return null;
    try {
      return RememberedIdentity(
        userId: userId,
        deviceId: deviceId,
        displayName: displayName,
      );
    } on FormatException {
      await forgetIdentity();
      return null;
    }
  }

  Future<void> rememberIdentity({
    required String userId,
    required String deviceId,
    required String displayName,
  }) async {
    RememberedIdentity(
      userId: userId,
      deviceId: deviceId,
      displayName: displayName,
    );
    final prefs = await SharedPreferences.getInstance();
    await _writeString(prefs, _rememberedUserIdKey, userId);
    await _writeString(prefs, _rememberedDeviceIdKey, deviceId);
    await _writeString(prefs, _rememberedDisplayNameKey, displayName);
  }

  Future<Session?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_userIdKey);
    final deviceId = prefs.getString(_deviceIdKey);
    final token = await _secrets.read(_tokenKey);
    // Never restore bearer credentials from ordinary preferences. Remove a
    // leftover legacy value instead of treating insecure storage as fallback.
    await _removeIfPresent(prefs, _tokenKey);
    final displayName = prefs.getString(_displayNameKey);
    if (userId == null ||
        deviceId == null ||
        token == null ||
        displayName == null) {
      // Remove orphaned credentials/metadata instead of retrying a partial
      // session forever on every process start.
      await clear();
      return null;
    }
    try {
      return Session(
        userId: userId,
        deviceId: deviceId,
        accessToken: token,
        displayName: displayName,
      );
    } on FormatException {
      await clear();
      return null;
    }
  }

  Future<void> clear() async {
    Object? firstError;
    try {
      // Authentication material is always the first deletion target.
      await _secrets.remove(_tokenKey);
    } catch (error) {
      firstError = error;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in <String>[
        _userIdKey,
        _deviceIdKey,
        _tokenKey,
        _displayNameKey,
      ]) {
        try {
          await _removeIfPresent(prefs, key);
        } catch (error) {
          firstError ??= error;
        }
      }
    } catch (error) {
      firstError ??= error;
    }
    if (firstError != null) {
      throw StateError('Unable to completely clear local session');
    }
  }

  /// Forget the account locator too. Used only by explicit profile deletion;
  /// normal logout intentionally keeps it for key-based sign-in.
  Future<void> forgetIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    await _removeIfPresent(prefs, _rememberedUserIdKey);
    await _removeIfPresent(prefs, _rememberedDeviceIdKey);
    await _removeIfPresent(prefs, _rememberedDisplayNameKey);
  }

  static Future<void> _writeString(
    SharedPreferences prefs,
    String key,
    String value,
  ) async {
    if (!await prefs.setString(key, value)) {
      throw StateError('Unable to persist session metadata');
    }
  }

  static Future<void> _removeIfPresent(
    SharedPreferences prefs,
    String key,
  ) async {
    if (prefs.containsKey(key) && !await prefs.remove(key)) {
      throw StateError('Unable to remove session metadata');
    }
  }
}

/// Narrow secret-storage boundary used by [SessionStore]. It allows the
/// persistence contract to be tested across fresh service instances without
/// replacing or weakening the production Keychain/Keystore/WebCrypto backend.
abstract interface class SessionSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

class PlatformSessionSecretStore implements SessionSecretStore {
  const PlatformSessionSecretStore();

  @override
  Future<String?> read(String key) => SecurePrefs.instance.read(key);

  @override
  Future<void> write(String key, String value) =>
      SecurePrefs.instance.write(key, value);

  @override
  Future<void> remove(String key) => SecurePrefs.instance.remove(key);
}

class RememberedIdentity {
  RememberedIdentity({
    required this.userId,
    required this.deviceId,
    required this.displayName,
  }) {
    _validateSessionText(userId, 'userId', 128);
    _validateSessionText(deviceId, 'deviceId', 128);
    _validateSessionText(displayName, 'displayName', 120);
  }

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
  }) {
    _validateSessionText(userId, 'userId', 128);
    _validateSessionText(deviceId, 'deviceId', 128);
    _validateSessionText(displayName, 'displayName', 120);
    _validateSessionText(accessToken, 'accessToken', 8192, minLength: 32);
  }

  factory Session.fromAuthResponse(
    Map<String, dynamic> response, {
    required String displayName,
  }) {
    final userId = response['user_id'];
    final deviceId = response['device_id'];
    final accessToken = response['access_token'];
    if (userId is! String || deviceId is! String || accessToken is! String) {
      throw const FormatException('invalid authentication response');
    }
    return Session(
      userId: userId,
      deviceId: deviceId,
      accessToken: accessToken,
      displayName: displayName,
    );
  }

  final String userId;
  final String deviceId;
  String accessToken;
  String displayName;
}

void _validateSessionText(
  String value,
  String field,
  int maxLength, {
  int minLength = 1,
}) {
  if (value.length < minLength ||
      value.length > maxLength ||
      value.codeUnits.any((unit) => unit < 32 || unit == 127)) {
    throw FormatException('invalid $field');
  }
}
