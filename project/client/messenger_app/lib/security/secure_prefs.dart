import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sensitive values in OS Keychain; falls back to SharedPreferences if Keychain unavailable.
///
/// On unsigned/local macOS builds the Data Protection Keychain needs entitlements
/// (-34018). We use the legacy login keychain and still fall back on any error.
class SecurePrefs {
  SecurePrefs._();
  static final instance = SecurePrefs._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    mOptions: MacOsOptions(
      groupId: 'com.messenger.messengerApp',
      useDataProtectionKeyChain: false,
    ),
  );

  Future<String?> read(String key) async {
    try {
      final secure = await _storage.read(key: key);
      if (secure != null) return secure;
    } catch (e) {
      debugPrint('SecurePrefs.read keychain miss for $key: $e');
    }

    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('secure_fallback::$key');
  }

  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('secure_fallback::$key');
      return;
    } catch (e) {
      debugPrint('SecurePrefs.write keychain failed for $key: $e');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('secure_fallback::$key', value);
  }

  Future<void> remove(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('secure_fallback::$key');
  }

  Future<bool> containsKey(String key) async {
    try {
      if (await _storage.containsKey(key: key)) return true;
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('secure_fallback::$key');
  }

  Future<void> clearKeys(Iterable<String> keys) async {
    for (final key in keys) {
      await remove(key);
    }
  }
}
