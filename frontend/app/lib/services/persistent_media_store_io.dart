import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'atomic_private_file_io.dart';
import 'media_backup_validation.dart';

/// Persistent ciphertext-only media cache for native platforms.
class PersistentMediaStore {
  PersistentMediaStore._();
  static final instance = PersistentMediaStore._();
  static const _maxManifestBytes = 2 * 1024 * 1024;

  Future<void> _operation = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _operation.then((_) => action());
    _operation = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

  Future<Directory> _userDirectory(String userId) async {
    validateMediaStorageUser(userId);
    final root = await getApplicationSupportDirectory();
    final cacheRoot = Directory(
      '${root.path}${Platform.pathSeparator}media-cache-v1',
    );
    await AtomicPrivateFile.secureDirectory(cacheRoot);
    final directory = Directory(
      '${cacheRoot.path}${Platform.pathSeparator}${_digest(userId)}',
    );
    await AtomicPrivateFile.secureDirectory(directory);
    return directory;
  }

  Future<File> _manifestFile(String userId) async => File(
    '${(await _userDirectory(userId)).path}${Platform.pathSeparator}manifest.json',
  );

  Future<Map<String, _MediaEntry>> _readManifest(String userId) async {
    final file = await _manifestFile(userId);
    final packed = await AtomicPrivateFile.readString(
      file,
      maxBytes: _maxManifestBytes,
    );
    if (packed == null) return {};
    final decoded = jsonDecode(packed);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('invalid media cache manifest');
    }
    if (decoded.length > maxMediaBackupEntries) {
      throw const FormatException('media cache manifest has too many entries');
    }
    final directory = await _userDirectory(userId);
    final entries = <String, _MediaEntry>{};
    var migrated = false;
    for (final item in decoded.entries) {
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(item.key) ||
          item.value is! Map<String, dynamic>) {
        throw const FormatException('invalid media cache entry');
      }
      var entry = _MediaEntry.fromJson(item.value as Map<String, dynamic>);
      if (entry.filename != '${_digest(item.key)}.bin') {
        throw const FormatException('invalid media cache filename');
      }
      if (entry.contentSha256 == null) {
        final mediaFile = File(
          '${directory.path}${Platform.pathSeparator}${entry.filename}',
        );
        if (!await AtomicPrivateFile.existsRegular(mediaFile) ||
            await mediaFile.length() != entry.size) {
          throw const FormatException('cannot migrate media cache entry');
        }
        final bytes = await mediaFile.readAsBytes();
        entry = entry.withContentSha256(sha256.convert(bytes).toString());
        migrated = true;
      }
      entries[item.key] = entry;
    }
    if (migrated) await _writeManifest(userId, entries);
    return entries;
  }

  Future<void> _writeManifest(
    String userId,
    Map<String, _MediaEntry> entries,
  ) async {
    if (entries.length > maxMediaBackupEntries) {
      throw const FormatException('media cache manifest has too many entries');
    }
    final file = await _manifestFile(userId);
    await AtomicPrivateFile.writeString(
      file,
      jsonEncode({
        for (final item in entries.entries) item.key: item.value.toJson(),
      }),
    );
  }

  Future<void> putCiphertext(String userId, String mediaId, Uint8List bytes) =>
      _serial(() async {
        validateMediaStorageInput(userId, mediaId, bytes: bytes);
        final manifest = await _readManifest(userId);
        final directory = await _userDirectory(userId);
        final filename = '${_digest(mediaId)}.bin';
        final file = File(
          '${directory.path}${Platform.pathSeparator}$filename',
        );
        await AtomicPrivateFile.writeBytes(file, bytes);
        manifest[mediaId] = _MediaEntry(
          filename: filename,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          size: bytes.length,
          contentSha256: sha256.convert(bytes).toString(),
        );
        await _writeManifest(userId, manifest);
      });

  Future<Uint8List?> getCiphertext(String userId, String mediaId) =>
      _serial(() async {
        validateMediaStorageInput(userId, mediaId);
        final entry = (await _readManifest(userId))[mediaId];
        if (entry == null) return null;
        final directory = await _userDirectory(userId);
        final file = File(
          '${directory.path}${Platform.pathSeparator}${entry.filename}',
        );
        if (!await AtomicPrivateFile.existsRegular(file)) return null;
        final actualLength = await file.length();
        if (actualLength != entry.size ||
            actualLength > maxMediaBackupItemBytes) {
          return null;
        }
        final bytes = await file.readAsBytes();
        if (sha256.convert(bytes).toString() != entry.contentSha256) {
          return null;
        }
        return Uint8List.fromList(bytes);
      });

  Future<void> clearUser(String userId) => _serial(() async {
    validateMediaStorageUser(userId);
    final root = await getApplicationSupportDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}media-cache-v1'
      '${Platform.pathSeparator}${_digest(userId)}',
    );
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<Map<String, String>> exportUser(String userId) => _serial(() async {
    validateMediaStorageUser(userId);
    final directory = await _userDirectory(userId);
    final manifest = await _readManifest(userId);
    final result = <String, String>{};
    var totalBytes = 0;
    for (final item in manifest.entries) {
      final file = File(
        '${directory.path}${Platform.pathSeparator}${item.value.filename}',
      );
      if (!await AtomicPrivateFile.existsRegular(file) ||
          await file.length() != item.value.size ||
          item.value.size > maxMediaBackupItemBytes) {
        throw const FormatException('media cache entry is unavailable');
      }
      totalBytes += item.value.size;
      if (totalBytes > maxMediaBackupTotalBytes) {
        throw const FormatException('media backup is too large');
      }
      final bytes = await file.readAsBytes();
      if (sha256.convert(bytes).toString() != item.value.contentSha256) {
        throw const FormatException('media cache integrity check failed');
      }
      result[item.key] = base64Encode(bytes);
    }
    return result;
  });

  Future<void> importUser(String userId, Map<String, dynamic> values) async {
    validateMediaStorageUser(userId);
    for (final item in decodeMediaBackup(values)) {
      await putCiphertext(userId, item.mediaId, item.bytes);
    }
  }

  Future<void> enforceLimits(
    String userId, {
    Duration? maxAge,
    required int maxBytes,
  }) => _serial(() async {
    validateMediaStorageUser(userId);
    if (maxBytes < 0) throw const FormatException('invalid media cache limit');
    final directory = await _userDirectory(userId);
    final manifest = await _readManifest(userId);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final ordered = manifest.entries.toList()
      ..sort((a, b) => a.value.createdAtMs.compareTo(b.value.createdAtMs));
    var total = ordered.fold<int>(0, (sum, item) => sum + item.value.size);
    for (final item in ordered) {
      final expired =
          maxAge != null &&
          nowMs - item.value.createdAtMs > maxAge.inMilliseconds;
      if (!expired && total <= maxBytes) continue;
      final file = File(
        '${directory.path}${Platform.pathSeparator}${item.value.filename}',
      );
      await AtomicPrivateFile.delete(file);
      total -= item.value.size;
      manifest.remove(item.key);
    }
    await _writeManifest(userId, manifest);
  });
}

class _MediaEntry {
  const _MediaEntry({
    required this.filename,
    required this.createdAtMs,
    required this.size,
    required this.contentSha256,
  });

  final String filename;
  final int createdAtMs;
  final int size;
  final String? contentSha256;

  factory _MediaEntry.fromJson(Map<String, dynamic> json) {
    final filename = json['filename'];
    final createdAtMs = json['created_at_ms'];
    final size = json['size'];
    final contentSha256 = json['content_sha256'];
    if (filename is! String ||
        !RegExp(r'^[a-f0-9]{64}\.bin$').hasMatch(filename) ||
        createdAtMs is! int ||
        size is! int ||
        size < 1 ||
        size > maxMediaBackupItemBytes ||
        (contentSha256 != null &&
            (contentSha256 is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(contentSha256)))) {
      throw const FormatException('invalid media cache entry');
    }
    return _MediaEntry(
      filename: filename,
      createdAtMs: createdAtMs,
      size: size,
      contentSha256: contentSha256 as String?,
    );
  }

  _MediaEntry withContentSha256(String value) => _MediaEntry(
    filename: filename,
    createdAtMs: createdAtMs,
    size: size,
    contentSha256: value,
  );

  Map<String, dynamic> toJson() => {
    'filename': filename,
    'created_at_ms': createdAtMs,
    'size': size,
    'content_sha256': contentSha256,
  };
}
