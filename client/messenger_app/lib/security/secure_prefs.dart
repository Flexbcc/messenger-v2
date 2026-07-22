import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sensitive values with Keychain + SharedPreferences fallback.
///
/// macOS: never use access-group without Keychain Sharing entitlements — that
/// triggers the Login password dialog. We still try the legacy group once to
/// recover keys written before that mistake, then mirror into prefs.
class SecurePrefs {
  SecurePrefs._();
  static final instance = SecurePrefs._();

  static bool get _isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );

  /// Pre-fix keys were written with this groupId (caused password prompts).
  static const _legacyMacStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    mOptions: MacOsOptions(
      groupId: 'com.messenger.messengerApp',
      useDataProtectionKeyChain: false,
    ),
  );

  Future<String?> read(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final fallbackKey = 'secure_fallback::$key';

    // 1) Current Keychain (no group)
    final fromKeychain = await _tryRead(_storage, key);
    if (fromKeychain != null) {
      await prefs.setString(fallbackKey, fromKeychain);
      return fromKeychain;
    }

    // 2) Legacy group Keychain — recover pre-break keys (may prompt once)
    if (_isMacOS) {
      final legacy = await _tryRead(_legacyMacStorage, key);
      if (legacy != null) {
        await prefs.setString(fallbackKey, legacy);
        try {
          await _storage.write(key: key, value: legacy);
        } catch (_) {}
        try {
          await _legacyMacStorage.delete(key: key);
        } catch (_) {}
        return legacy;
      }
    }

    return prefs.getString(fallbackKey);
  }

  Future<String?> _tryRead(FlutterSecureStorage storage, String key) async {
    try {
      final value = await storage.read(key: key);
      if (value != null && value.isNotEmpty) return value;
    } catch (e) {
      debugPrint('SecurePrefs.read miss for $key: $e');
    }
    return null;
  }

  Future<void> write(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('secure_fallback::$key', value);

    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      debugPrint('SecurePrefs.write keychain failed for $key: $e');
    }
  }

  Future<void> remove(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {}
    if (_isMacOS) {
      try {
        await _legacyMacStorage.delete(key: key);
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('secure_fallback::$key');
  }

  Future<bool> containsKey(String key) async {
    if (await _tryRead(_storage, key) != null) return true;
    if (_isMacOS && await _tryRead(_legacyMacStorage, key) != null) return true;
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('secure_fallback::$key');
  }

  Future<void> clearKeys(Iterable<String> keys) async {
    for (final key in keys) {
      await remove(key);
    }
  }
}
