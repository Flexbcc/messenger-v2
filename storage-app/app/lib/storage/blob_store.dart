// storage-app :: storage/blob_store
// Файловое хранилище блобов (SETTINGS.md §2). Контентная адресация по
// sha256(шифротекста). Atomic write через .tmp, идемпотентный PUT, integrity,
// защита от path traversal (запись строго внутри allowed_root).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Результат PUT.
enum PutOutcome { created, alreadyExists }

/// Ошибка целостности: sha256(body) != hash в пути → WIRE.md 422.
class IntegrityError implements Exception {
  final String expected;
  final String actual;
  IntegrityError(this.expected, this.actual);
  @override
  String toString() => 'IntegrityError(expected=$expected, actual=$actual)';
}

/// Некорректный user_id/hash (traversal, пустые, неверный формат) → 400/404.
class InvalidAddressError implements Exception {
  final String message;
  InvalidAddressError(this.message);
  @override
  String toString() => 'InvalidAddressError($message)';
}

class BlobStore {
  final String allowedRoot;
  late final String _rootAbs;

  BlobStore(this.allowedRoot) {
    _rootAbs = p.normalize(Directory(allowedRoot).absolute.path);
  }

  static final _hexHash = RegExp(r'^[0-9a-f]{64}$');
  // user_id: uuid-подобный или безопасный идентификатор (без разделителей пути).
  static final _safeUser = RegExp(r'^[A-Za-z0-9_\-]{1,128}$');

  /// Абсолютный путь к блобу; кидает InvalidAddressError при traversal.
  String blobPath(String userId, String hash) {
    if (!_safeUser.hasMatch(userId)) {
      throw InvalidAddressError('bad user_id');
    }
    if (!_hexHash.hasMatch(hash)) {
      throw InvalidAddressError('bad hash');
    }
    final aa = hash.substring(0, 2);
    final bb = hash.substring(2, 4);
    final path = p.normalize(
        p.join(_rootAbs, 'users', userId, 'blobs', aa, bb, hash));
    // Двойная защита: итоговый путь обязан лежать внутри allowed_root.
    if (!p.isWithin(_rootAbs, path)) {
      throw InvalidAddressError('path escapes allowed_root');
    }
    return path;
  }

  String get _tmpDir => p.join(_rootAbs, '.tmp');

  /// Идемпотентный atomic PUT. Проверяет sha256(bytes)==hash.
  /// Возвращает outcome + фактический размер.
  Future<({PutOutcome outcome, int size})> put(
      String userId, String hash, Uint8List bytes) async {
    final actual = sha256.convert(bytes).toString();
    if (actual != hash) {
      throw IntegrityError(hash, actual);
    }
    final dest = blobPath(userId, hash);
    final destFile = File(dest);
    if (await destFile.exists()) {
      // Идемпотентность: не перезаписываем (WIRE.md §Адресация).
      return (outcome: PutOutcome.alreadyExists, size: bytes.length);
    }
    await destFile.parent.create(recursive: true);
    await Directory(_tmpDir).create(recursive: true);
    final tmp = File(p.join(
        _tmpDir, '$hash.${DateTime.now().microsecondsSinceEpoch}.tmp'));
    await tmp.writeAsBytes(bytes, flush: true);
    try {
      await tmp.rename(dest);
    } on FileSystemException {
      // Гонка: другой PUT уже переименовал — считаем существующим.
      if (await destFile.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
        return (outcome: PutOutcome.alreadyExists, size: bytes.length);
      }
      rethrow;
    }
    return (outcome: PutOutcome.created, size: bytes.length);
  }

  Future<bool> exists(String userId, String hash) =>
      File(blobPath(userId, hash)).exists();

  /// Открыть файл блоба для потоковой отдачи; null если нет на диске.
  Future<File?> openBlobFile(String userId, String hash) async {
    final f = File(blobPath(userId, hash));
    if (!await f.exists()) return null;
    return f;
  }

  /// Загрузка целиком в RAM (тесты / мелкие блобы).
  Future<Uint8List?> get(String userId, String hash) async {
    final f = await openBlobFile(userId, hash);
    if (f == null) return null;
    return f.readAsBytes();
  }

  /// Идемпотентное удаление. true если файл был.
  Future<bool> delete(String userId, String hash) async {
    final f = File(blobPath(userId, hash));
    if (!await f.exists()) return false;
    await f.delete();
    return true;
  }

  /// Удалить всю папку пользователя `users/<user_id>/` (revoke + wipe).
  Future<void> deleteUserData(String userId) async {
    if (!_safeUser.hasMatch(userId)) {
      throw InvalidAddressError('bad user_id');
    }
    final dir = Directory(p.join(_rootAbs, 'users', userId));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
