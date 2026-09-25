import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../security/crypto_encoding.dart';

const _allowLegacyBackupKdf = bool.fromEnvironment(
  'ALLOW_LEGACY_BACKUP_KDF',
  defaultValue: false,
);

/// AES-GCM blob encryption for catalog backups (uses project `cryptography`).
class BackupCrypto {
  BackupCrypto._();

  static final _aes = AesGcm.with256bits();

  static Future<Map<String, dynamic>> encryptJson(
    Map<String, dynamic> blob,
    String password,
  ) async {
    if (password.length < 12) {
      throw const FormatException(
        'Пароль резервной копии должен содержать не менее 12 символов',
      );
    }
    final plain = utf8.encode(const JsonEncoder().convert(blob));
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final secretKey = await _deriveKey(password, salt);
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(plain, secretKey: secretKey, nonce: nonce);
    return {
      'kind': 'encrypted_settings_backup',
      'alg': 'aes-gcm-256',
      'kdf': 'argon2id-v1',
      'salt': base64Encode(salt),
      'nonce': base64Encode(box.nonce),
      'mac': base64Encode(box.mac.bytes),
      'ciphertext': base64Encode(box.cipherText),
    };
  }

  static Future<Map<String, dynamic>> decryptJson(
    Map<String, dynamic> envelope,
    String password,
  ) async {
    if (envelope['kind'] != 'encrypted_settings_backup' ||
        envelope['alg'] != 'aes-gcm-256') {
      throw const FormatException('Неподдерживаемый формат резервной копии');
    }
    const allowedFields = {
      'kind',
      'alg',
      'kdf',
      'salt',
      'nonce',
      'mac',
      'ciphertext',
    };
    const requiredFields = {
      'kind',
      'alg',
      'salt',
      'nonce',
      'mac',
      'ciphertext',
    };
    if (!envelope.keys.toSet().containsAll(requiredFields) ||
        envelope.keys.any((key) => !allowedFields.contains(key))) {
      throw const FormatException('Структура резервной копии повреждена');
    }
    final salt = decodeBase64Exact(
      envelope['salt'],
      expectedBytes: 16,
      field: 'backup salt',
      maxEncodedCharacters: 32,
    );
    final nonce = decodeBase64Exact(
      envelope['nonce'],
      expectedBytes: 12,
      field: 'backup nonce',
      maxEncodedCharacters: 24,
    );
    final macBytes = decodeBase64Exact(
      envelope['mac'],
      expectedBytes: 16,
      field: 'backup authentication tag',
      maxEncodedCharacters: 32,
    );
    final cipher = _decodeBounded(
      envelope['ciphertext'],
      min: 1,
      max: 256 * 1024 * 1024,
    );
    final mac = Mac(macBytes);
    final kdf = envelope['kdf'];
    final SecretKey secretKey;
    if (kdf == 'argon2id-v1') {
      if (password.length < 12) {
        throw const FormatException('Пароль резервной копии слишком короткий');
      }
      secretKey = await _deriveKey(password, salt);
    } else if (kdf == null && _allowLegacyBackupKdf) {
      secretKey = await _deriveLegacyKey(password, salt);
    } else {
      throw const FormatException('Неподдерживаемая функция выработки ключа');
    }
    final plain = await _aes.decrypt(
      SecretBox(cipher, nonce: nonce, mac: mac),
      secretKey: secretKey,
    );
    final decoded = jsonDecode(utf8.decode(plain));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Резервная копия должна содержать объект');
    }
    return decoded;
  }

  static Future<SecretKey> _deriveKey(String password, List<int> salt) async {
    final argon2 = Argon2id(
      parallelism: 1,
      memory: 65536,
      iterations: 3,
      hashLength: 32,
    );
    return argon2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  static Future<SecretKey> _deriveLegacyKey(
    String password,
    List<int> salt,
  ) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    );
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  static Uint8List encodeEnvelope(Map<String, dynamic> envelope) =>
      Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(envelope)),
      );

  static List<int> _decodeBounded(
    Object? value, {
    required int min,
    required int max,
  }) {
    if (value is! String || value.length > (max * 4 ~/ 3) + 8) {
      throw const FormatException('Некорректное поле резервной копии');
    }
    return decodeBase64Bounded(
      value,
      minimumBytes: min,
      maximumBytes: max,
      field: 'backup field',
      maxEncodedCharacters: (max * 4 ~/ 3) + 8,
    );
  }
}
