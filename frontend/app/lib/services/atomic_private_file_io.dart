import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Native-file primitives for small security-sensitive application state.
class AtomicPrivateFile {
  AtomicPrivateFile._();

  static final Random _random = Random.secure();

  static Future<bool> existsRegular(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file) {
      throw const FileSystemException('protected path is not a regular file');
    }
    return true;
  }

  static Future<String?> readString(File file, {required int maxBytes}) async {
    if (maxBytes < 1) throw ArgumentError.value(maxBytes, 'maxBytes');
    if (!await existsRegular(file)) return null;
    final length = await file.length();
    if (length < 1 || length > maxBytes) {
      throw const FormatException('protected file has invalid size');
    }
    return file.readAsString();
  }

  static Future<void> writeString(File file, String value) async {
    await writeBytes(file, utf8.encode(value));
  }

  static Future<void> secureDirectory(Directory directory) async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      await directory.create(recursive: true);
    } else if (type != FileSystemEntityType.directory) {
      throw const FileSystemException(
        'protected path is not a regular directory',
      );
    }
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final result = await Process.run('chmod', ['700', directory.path]);
    if (result.exitCode != 0) {
      throw const FileSystemException('could not secure protected directory');
    }
  }

  static Future<void> writeBytes(File file, List<int> value) async {
    await file.parent.create(recursive: true);
    await existsRegular(file);
    final suffix = List<int>.generate(
      16,
      (_) => _random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final temporary = File('${file.path}.$suffix.tmp');
    try {
      await temporary.writeAsBytes(value, flush: true);
      await _makePrivate(temporary.path);
      if (Platform.isWindows && await existsRegular(file)) {
        final backup = File('${file.path}.$suffix.bak');
        await file.rename(backup.path);
        try {
          await temporary.rename(file.path);
          await backup.delete();
        } catch (_) {
          if (!await file.exists() && await backup.exists()) {
            await backup.rename(file.path);
          }
          rethrow;
        }
      } else {
        await temporary.rename(file.path);
      }
      await _makePrivate(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static Future<void> delete(File file) async {
    if (await existsRegular(file)) await file.delete();
  }

  static Future<void> _makePrivate(String path) async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final result = await Process.run('chmod', ['600', path]);
    if (result.exitCode != 0) {
      throw const FileSystemException('could not secure protected file');
    }
  }
}
