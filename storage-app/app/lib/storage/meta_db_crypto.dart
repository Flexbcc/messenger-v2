// storage-app :: storage/meta_db_crypto
// Прикладное AES-GCM шифрование файла meta.db (SETTINGS.md §3).
//
// Формат v1: `PPC1` ‖ version(1) ‖ nonce(12) ‖ ciphertext ‖ mac(16).
// Legacy (до v1): nonce(12) ‖ ciphertext ‖ mac(16) — без magic-заголовка.
// Целостность: AES-GCM authentication tag (отдельный HMAC не нужен).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

/// Шифрование SQLite-файла meta.db at-rest.
class MetaDbCrypto {
  MetaDbCrypto._();

  static final _aesGcm = AesGcm.with256bits();
  static const _nonceLen = 12;
  static const _macLen = 16;

  /// Magic + version для распознавания формата на диске.
  static const _magic = [0x50, 0x50, 0x43, 0x31]; // "PPC1"
  static const _formatVersion = 1;

  static String encryptedPath(String dbPath) => '$dbPath.enc';

  /// Зашифровать plaintext [dbPath] → [dbPath].enc, безопасно удалить исходник и WAL/SHM.
  static Future<void> encryptDatabaseFile(String dbPath, List<int> key) async {
    final plain = await File(dbPath).readAsBytes();
    final packed = await _encryptBytes(plain, key);
    final encPath = encryptedPath(dbPath);
    final tmpPath = '$encPath.tmp';
    await File(tmpPath).writeAsBytes(packed, flush: true);
    await File(tmpPath).rename(encPath);
    await _deleteSqliteSidecars(dbPath);
    await _secureDelete(File(dbPath));
  }

  /// Зашифровать копию [dbPath] → [dbPath].enc, plaintext оставить (long-running flush).
  static Future<void> encryptDatabaseCopy(String dbPath, List<int> key) async {
    final plain = await File(dbPath).readAsBytes();
    final packed = await _encryptBytes(plain, key);
    final encPath = encryptedPath(dbPath);
    final tmpPath = '$encPath.tmp';
    await File(tmpPath).writeAsBytes(packed, flush: true);
    await File(tmpPath).rename(encPath);
  }

  /// Расшифровать [encPath] → [dbPath], удалить .enc.
  static Future<void> decryptDatabaseFile(
    String encPath,
    String dbPath,
    List<int> key,
  ) async {
    final packed = await File(encPath).readAsBytes();
    final plain = await _decryptBytes(packed, key);
    await File(dbPath).writeAsBytes(plain, flush: true);
    await File(encPath).delete();
  }

  /// Crash mid-shutdown: оба meta.db и meta.db.enc на диске.
  ///
  /// Политика восстановления (best-effort):
  /// 1. Проверяем валидность SQLite-заголовка у plaintext и у расшифровки .enc.
  /// 2. Если валиден только один источник — берём его.
  /// 3. Если оба валидны — предпочитаем более новый по mtime (plain новее → правки
  ///    после незавершённого close; .enc новее → редкий случай, plain устарел).
  /// 4. Если plaintext битый, а .enc валиден — расшифровываем .enc поверх plain.
  /// 5. Если plain валиден, .enc битый/не расшифровывается — оставляем plain,
  ///    удаляем битый .enc; re-encrypt на следующем close().
  /// 6. Если оба битые — бросаем StateError (ручное восстановление из бэкапа).
  static Future<void> recoverCrashState(
    String dbPath,
    String encPath,
    List<int> key,
  ) async {
    final plainFile = File(dbPath);
    final encFile = File(encPath);

    final plainBytes = await plainFile.readAsBytes();
    final plainValid = _looksLikeSqlite(plainBytes);

    Uint8List? decBytes;
    var encValid = false;
    try {
      final packed = await encFile.readAsBytes();
      decBytes = await _decryptBytes(packed, key);
      encValid = _looksLikeSqlite(decBytes);
    } catch (_) {
      encValid = false;
    }

    if (plainValid && encValid) {
      final plainMtime = await plainFile.lastModified();
      final encMtime = await encFile.lastModified();
      if (plainMtime.isAfter(encMtime) ||
          plainMtime.isAtSameMomentAs(encMtime)) {
        // Plaintext новее или совпадает — stale .enc от прерванного close.
        await encFile.delete();
      } else {
        await plainFile.writeAsBytes(decBytes!, flush: true);
        await encFile.delete();
      }
      return;
    }

    if (plainValid) {
      try {
        await encFile.delete();
      } catch (_) {}
      return;
    }

    if (encValid) {
      await plainFile.writeAsBytes(decBytes!, flush: true);
      await encFile.delete();
      return;
    }

    throw StateError(
      'meta.db crash recovery failed: both plaintext and meta.db.enc are invalid',
    );
  }

  /// SQLite file header: "SQLite format 3\\0".
  static bool _looksLikeSqlite(List<int> bytes) {
    if (bytes.length < 16) return false;
    const header = 'SQLite format 3';
    for (var i = 0; i < header.length; i++) {
      if (bytes[i] != header.codeUnitAt(i)) return false;
    }
    return bytes[15] == 0;
  }

  static Future<Uint8List> _encryptBytes(List<int> plain, List<int> key) async {
    final secretKey = SecretKey(key);
    final box = await _aesGcm.encrypt(plain, secretKey: secretKey);
    return Uint8List.fromList([
      ..._magic,
      _formatVersion,
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  static Future<Uint8List> _decryptBytes(
    List<int> packed,
    List<int> key,
  ) async {
    final (nonce, cipher, mac) = _parsePacked(packed);
    final secretKey = SecretKey(key);
    final clear = await _aesGcm.decrypt(
      SecretBox(cipher, nonce: nonce, mac: mac),
      secretKey: secretKey,
    );
    return Uint8List.fromList(clear);
  }

  /// Разбор v1 (`PPC1`…) или legacy (nonce‖cipher‖mac).
  static (List<int> nonce, List<int> cipher, Mac mac) _parsePacked(
    List<int> packed,
  ) {
    final hasMagic = packed.length >= _magic.length + 1 &&
        packed[0] == _magic[0] &&
        packed[1] == _magic[1] &&
        packed[2] == _magic[2] &&
        packed[3] == _magic[3];

    if (hasMagic) {
      // v1: PPC1 ‖ version ‖ nonce ‖ cipher ‖ mac
      if (packed.length <= _magic.length + 1 + _nonceLen + _macLen) {
        throw FormatException('meta.db.enc: truncated v1 ciphertext');
      }
      final version = packed[_magic.length];
      if (version != _formatVersion) {
        throw FormatException('meta.db.enc: unsupported format version $version');
      }
      final off = _magic.length + 1;
      final nonce = packed.sublist(off, off + _nonceLen);
      final mac = Mac(packed.sublist(packed.length - _macLen));
      final cipher =
          packed.sublist(off + _nonceLen, packed.length - _macLen);
      return (nonce, cipher, mac);
    }

    // Legacy: nonce ‖ cipher ‖ mac (pre-PPC1 deployments).
    if (packed.length <= _nonceLen + _macLen) {
      throw FormatException('meta.db.enc: truncated legacy ciphertext');
    }
    final nonce = packed.sublist(0, _nonceLen);
    final mac = Mac(packed.sublist(packed.length - _macLen));
    final cipher = packed.sublist(_nonceLen, packed.length - _macLen);
    return (nonce, cipher, mac);
  }

  /// Best-effort однократная перезапись нулями перед unlink.
  static Future<void> _secureDelete(File file) async {
    if (!await file.exists()) return;
    try {
      final len = await file.length();
      if (len > 0) {
        final raf = await file.open(mode: FileMode.write);
        try {
          const chunk = 65536;
          final zeros = Uint8List(chunk);
          var remaining = len;
          while (remaining > 0) {
            final n = remaining < chunk ? remaining : chunk;
            await raf.writeFrom(n < chunk ? zeros.sublist(0, n) : zeros);
            remaining -= n;
          }
          await raf.flush();
        } finally {
          await raf.close();
        }
      }
    } catch (_) {
      // Best-effort: FS/journal may ignore overwrite; still delete below.
    }
    await file.delete();
  }

  static Future<void> _deleteSqliteSidecars(String dbPath) async {
    for (final suffix in ['-wal', '-shm']) {
      final sidecar = File('$dbPath$suffix');
      if (await sidecar.exists()) {
        await sidecar.delete();
      }
    }
  }

  /// Путь meta.db внутри allowed_root.
  static String dbPath(String allowedRoot) =>
      p.join(allowedRoot, 'meta.db');
}
