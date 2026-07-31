// storage-app :: storage/blob_gc
// Плановый GC: meta.db collectGarbage + очистка файлов (SETTINGS.md §7).
library;

import 'blob_store.dart';
import 'meta_db.dart';

class BlobGcRunner {
  final MetaDb metaDb;
  final BlobStore blobStore;
  final int ttlDays;

  BlobGcRunner({
    required this.metaDb,
    required this.blobStore,
    this.ttlDays = 0,
  });

  /// Один проход GC. Возвращает число удалённых метаданных.
  Future<int> runOnce() async {
    final removed = metaDb.collectGarbage(ttlDays: ttlDays);
    for (final r in removed) {
      try {
        await blobStore.delete(r.userUuid, r.hash);
      } on InvalidAddressError {
        // некорректный адрес — пропускаем
      }
    }
    return removed.length;
  }
}
