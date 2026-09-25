import 'dart:typed_data';

import 'media_backup_validation.dart';

/// Fail-closed implementation for targets without a durable media backend.
///
/// Attachment transport remains available because callers treat this store as
/// a local cache. Backup and cache-management operations must not pretend that
/// volatile process memory is persistent storage.
class PersistentMediaStore {
  PersistentMediaStore._();
  static final instance = PersistentMediaStore._();

  Never _unsupported() => throw UnsupportedError(
    'Persistent media storage is not supported on this platform',
  );

  Future<void> putCiphertext(
    String userId,
    String mediaId,
    Uint8List bytes,
  ) async {
    validateMediaStorageInput(userId, mediaId, bytes: bytes);
    _unsupported();
  }

  Future<Uint8List?> getCiphertext(String userId, String mediaId) async {
    validateMediaStorageInput(userId, mediaId);
    _unsupported();
  }

  Future<void> clearUser(String userId) async {
    validateMediaStorageUser(userId);
    // No durable backend means there is nothing to erase. This must remain a
    // successful idempotent cleanup so logout cannot be blocked.
  }

  Future<Map<String, String>> exportUser(String userId) async {
    validateMediaStorageUser(userId);
    _unsupported();
  }

  Future<void> importUser(String userId, Map<String, dynamic> values) async {
    validateMediaStorageUser(userId);
    decodeMediaBackup(values);
    _unsupported();
  }

  Future<void> enforceLimits(
    String userId, {
    Duration? maxAge,
    required int maxBytes,
  }) async {
    validateMediaStorageUser(userId);
    if (maxBytes < 0) throw const FormatException('invalid media cache limit');
    // No durable entries exist on this target, so the requested limit already
    // holds. Reads, writes and backups still fail explicitly above.
  }
}
