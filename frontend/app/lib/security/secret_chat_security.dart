import 'dart:convert';

import '../services/account_scope_id.dart';
import '../services/local_settings_store.dart';
import '../services/security_meta_store.dart';
import 'pin_security.dart';
import 'secure_prefs.dart';

/// Password for in-chat secret session (`пароль␠␠` activation).
class SecretChatSecurity {
  SecretChatSecurity._();

  static const _hashKeyBase = 'secret_chat_password_hash';
  static const _saltKeyBase = 'secret_chat_password_salt';
  static final _secure = SecurePrefs.instance;

  static String get _hashKey => _scoped(_hashKeyBase);
  static String get _saltKey => _scoped(_saltKeyBase);

  static String _scoped(String base) {
    final userId = AccountScopeId.require(LocalSettingsStore.activeUserId);
    return '${base}_u_$userId';
  }

  static Future<bool> isConfigured() async {
    final hash = await _secure.read(_hashKey);
    final salt = await _secure.read(_saltKey);
    if (hash == null || salt == null) return false;
    try {
      return base64Decode(hash).length == 32 && base64Decode(salt).length == 16;
    } on FormatException {
      return false;
    }
  }

  static Future<void> savePassword(String password) async {
    final errors = blockingErrorsForSetup(password);
    if (errors.isNotEmpty) throw FormatException(errors.join('; '));
    final normalized = _normalizeForSave(password);
    final salt = PinSecurity.newSalt();
    final hash = await PinSecurity.hashToBase64(normalized, salt);
    await _secure.replacePair(
      firstKey: _saltKey,
      firstValue: base64Encode(salt),
      secondKey: _hashKey,
      secondValue: hash,
    );
    await SecurityMetaStore.instance.recordPinChange();
  }

  static Future<void> clearPassword() async {
    await _secure.clearKeys([_hashKey, _saltKey]);
  }

  /// Old releases shared these credentials between every account. Never
  /// migrate them into an arbitrary currently active account.
  static Future<void> clearLegacyUnscopedKeys() async {
    await _secure.clearKeys([_hashKeyBase, _saltKeyBase]);
  }

  static Future<bool> verify(String password) async {
    final hash = await _secure.read(_hashKey);
    final saltB64 = await _secure.read(_saltKey);
    if (hash == null || saltB64 == null) return false;
    return PinSecurity.verifyHash(password, saltB64, hash);
  }

  /// Validation errors for UI (empty list = ok).
  static List<String> validateForSetup(String password) {
    return [...blockingErrorsForSetup(password), ...warningsForSetup(password)];
  }

  /// Requirements that cannot be bypassed from the UI.
  static List<String> blockingErrorsForSetup(String password) {
    final errors = <String>[];
    if (password.length < 8) {
      errors.add('Минимум 8 символов');
    }
    if (password.length > 128) {
      errors.add('Максимум 128 символов');
    }
    if (password.codeUnits.any((unit) => unit < 32 || unit == 127)) {
      errors.add('Управляющие символы запрещены');
    }
    if (password.endsWith(' ') || password.endsWith('\t')) {
      errors.add('Не должно заканчиваться пробелом');
    }
    return errors;
  }

  /// Recommendations which an informed user may explicitly override.
  static List<String> warningsForSetup(String password) {
    final warnings = <String>[];
    if (password == password.toLowerCase() && password.length < 12) {
      warnings.add('Добавьте цифры или заглавные буквы');
    }
    const weak = {'привет', 'hello', 'password', '12345678', 'ок', 'да', 'нет'};
    if (weak.contains(password.toLowerCase().trim())) {
      warnings.add('Слишком простой пароль');
    }
    return warnings;
  }

  static String _normalizeForSave(String password) => password;

  /// `password␠␠` — password part without trailing sentinel spaces.
  static bool looksLikeActivationAttempt(String raw) => raw.endsWith('  ');
}
