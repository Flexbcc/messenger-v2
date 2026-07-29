// Re-export SecurePrefs as SecureStorage for use in crypto/ and services/.
// SecurePrefs is the canonical secure key-value store — it handles macOS
// Keychain quirks, Android EncryptedSharedPrefs, and a SharedPreferences
// fallback. See security/secure_prefs.dart for implementation.
export '../security/secure_prefs.dart' show SecurePrefs;

// Alias so callers can do SecureStorage.instance without referencing SecurePrefs.
import '../security/secure_prefs.dart';

class SecureStorage {
  SecureStorage._();

  static SecurePrefs get instance => SecurePrefs.instance;
}
