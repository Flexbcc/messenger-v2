import 'dart:typed_data';
import 'dart:convert';

import 'package:idb_shim/idb_browser.dart';

/// Durable PWA store for E2EE ciphertext. IndexedDB never receives the media
/// key; that key remains inside the encrypted message pointer.
class PersistentMediaStore {
  PersistentMediaStore._();
  static final instance = PersistentMediaStore._();

  static const _dbName = 'ouo_media_v1';
  static const _storeName = 'ciphertext';

  Future<Database> _open() => idbFactoryBrowser.open(
    _dbName,
    version: 1,
    onUpgradeNeeded: (event) {
      if (!event.database.objectStoreNames.contains(_storeName)) {
        event.database.createObjectStore(_storeName);
      }
    },
  );

  String _key(String userId, String mediaId) => '$userId::$mediaId';

  Future<void> putCiphertext(
    String userId,
    String mediaId,
    Uint8List bytes,
  ) async {
    final db = await _open();
    final txn = db.transaction(_storeName, idbModeReadWrite);
    await txn.objectStore(_storeName).put({
      'user_id': userId,
      'media_id': mediaId,
      'bytes': bytes,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, _key(userId, mediaId));
    await txn.completed;
    db.close();
  }

  Future<Uint8List?> getCiphertext(String userId, String mediaId) async {
    final db = await _open();
    final txn = db.transaction(_storeName, idbModeReadOnly);
    final raw = await txn
        .objectStore(_storeName)
        .getObject(_key(userId, mediaId));
    await txn.completed;
    db.close();
    if (raw is! Map) return null;
    final bytes = raw['bytes'];
    return bytes is Uint8List
        ? bytes
        : Uint8List.fromList((bytes as List).cast<int>());
  }

  Future<void> clearUser(String userId) async {
    await _mutateUser(userId, (key, value, store) async {
      await store.delete(key);
    });
  }

  Future<Map<String, String>> exportUser(String userId) async {
    final db = await _open();
    final txn = db.transaction(_storeName, idbModeReadOnly);
    final values = await txn.objectStore(_storeName).getAll();
    await txn.completed;
    db.close();
    return {
      for (final value in values)
        if (value is Map && value['user_id'] == userId)
          value['media_id'] as String: base64Encode(
            value['bytes'] is Uint8List
                ? value['bytes'] as Uint8List
                : (value['bytes'] as List).cast<int>(),
          ),
    };
  }

  Future<void> importUser(String userId, Map<String, dynamic> values) async {
    for (final entry in values.entries) {
      if (entry.value is String) {
        await putCiphertext(
          userId,
          entry.key,
          base64Decode(entry.value as String),
        );
      }
    }
  }

  Future<void> enforceLimits(
    String userId, {
    Duration? maxAge,
    required int maxBytes,
  }) async {
    final db = await _open();
    final read = db.transaction(_storeName, idbModeReadOnly);
    final store = read.objectStore(_storeName);
    final keys = await store.getAllKeys();
    final values = await store.getAll();
    await read.completed;
    final entries = <({Object key, Map value})>[];
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value is Map && value['user_id'] == userId) {
        entries.add((key: keys[i], value: value));
      }
    }
    entries.sort(
      (a, b) => (a.value['created_at'] as int).compareTo(
        b.value['created_at'] as int,
      ),
    );
    var total = entries.fold<int>(
      0,
      (sum, entry) => sum + (entry.value['bytes'] as List).length,
    );
    final cutoff = maxAge == null
        ? null
        : DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    final remove = <Object>[];
    for (final entry in entries) {
      final expired =
          cutoff != null && (entry.value['created_at'] as int) < cutoff;
      if (expired || total > maxBytes) {
        remove.add(entry.key);
        total -= (entry.value['bytes'] as List).length;
      }
    }
    if (remove.isNotEmpty) {
      final write = db.transaction(_storeName, idbModeReadWrite);
      final writeStore = write.objectStore(_storeName);
      for (final key in remove) {
        await writeStore.delete(key);
      }
      await write.completed;
    }
    db.close();
  }

  Future<void> _mutateUser(
    String userId,
    Future<void> Function(Object key, Map value, ObjectStore store) action,
  ) async {
    final db = await _open();
    final txn = db.transaction(_storeName, idbModeReadWrite);
    final store = txn.objectStore(_storeName);
    final keys = await store.getAllKeys();
    final values = await store.getAll();
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value is Map && value['user_id'] == userId) {
        await action(keys[i], value, store);
      }
    }
    await txn.completed;
    db.close();
  }
}
