import 'dart:convert';

import '../services/security_meta_store.dart';
import 'pin_security.dart';
import 'secure_prefs.dart';

/// Password for in-chat secret session (`пароль␠␠` activation).
class SecretChatSecurity {
  SecretChatSecurity._();

  static const hashKey = 'secret_chat_password_hash';
  static const saltKey = 'secret_chat_password_salt';
  static final _secure = SecurePrefs.instance;

  static Future<bool> isConfigured() async => _secure.containsKey(hashKey);

  static Future<void> savePassword(String password) async {
    final normalized = _normalizeForSave(password);
    final salt = PinSecurity.newSalt();
    final hash = await PinSecurity.hashToBase64(normalized, salt);
    await _secure.write(hashKey, hash);
    await _secure.write(saltKey, base64Encode(salt));
    await SecurityMetaStore.instance.recordPinChange();
  }

  static Future<void> clearPassword() async {
    await _secure.remove(hashKey);
    await _secure.remove(saltKey);
  }

  static Future<bool> verify(String password) async {
    final hash = await _secure.read(hashKey);
    final saltB64 = await _secure.read(saltKey);
    if (hash == null || saltB64 == null) return false;
    final candidate = await PinSecurity.hashToBase64(
      password,
      base64Decode(saltB64),
    );
    return candidate == hash;
  }

  /// Validation errors for UI (empty list = ok).
  static List<String> validateForSetup(String password) {
    final errors = <String>[];
    if (password.length < 8) {
      errors.add('Минимум 8 символов');
    }
    if (password.endsWith(' ') || password.endsWith('\t')) {
      errors.add('Не должно заканчиваться пробелом');
    }
    if (password == password.toLowerCase() && password.length < 12) {
      errors.add('Добавьте цифры или заглавные буквы');
    }
    const weak = {'привет', 'hello', 'password', '12345678', 'ок', 'да', 'нет'};
    if (weak.contains(password.toLowerCase().trim())) {
      errors.add('Слишком простой пароль');
    }
    return errors;
  }

  static String _normalizeForSave(String password) => password;

  /// `password␠␠` — password part without trailing sentinel spaces.
  static bool looksLikeActivationAttempt(String raw) => raw.endsWith('  ');
}
