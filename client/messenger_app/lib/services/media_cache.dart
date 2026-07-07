import 'dart:typed_data';

/// In-memory cache for decrypted media bytes downloaded this session.
/// Size is real — "Очистить кэш" wipes this map (design.md §14).
class MediaCache {
  MediaCache._();
  static final instance = MediaCache._();

  final _entries = <String, Uint8List>{};

  int get totalBytes => _entries.values.fold<int>(0, (sum, bytes) => sum + bytes.length);

  Uint8List? get(String mediaId) => _entries[mediaId];

  void put(String mediaId, Uint8List bytes) => _entries[mediaId] = bytes;

  void clear() => _entries.clear();
}
