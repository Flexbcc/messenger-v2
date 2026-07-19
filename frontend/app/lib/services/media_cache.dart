import 'dart:typed_data';

import 'settings_runtime.dart';

class _CacheEntry {
  _CacheEntry(this.bytes) : createdAt = DateTime.now(), lastAccess = DateTime.now();

  final Uint8List bytes;
  final DateTime createdAt;
  DateTime lastAccess;
}

/// In-memory cache for decrypted media bytes downloaded this session.
/// Enforces [media.cache_limit_gb] and optional age cleanup from catalog.
class MediaCache {
  MediaCache._();
  static final instance = MediaCache._();

  final _entries = <String, _CacheEntry>{};

  int get totalBytes => _entries.values.fold<int>(0, (sum, e) => sum + e.bytes.length);

  int get entryCount => _entries.length;

  Uint8List? get(String mediaId) {
    final entry = _entries[mediaId];
    if (entry == null) return null;
    entry.lastAccess = DateTime.now();
    return entry.bytes;
  }

  void put(String mediaId, Uint8List bytes) {
    _entries[mediaId] = _CacheEntry(bytes);
    // Fire-and-forget limit enforcement (prefs are async).
    // ignore: discarded_futures
    enforceLimits();
  }

  void clear() => _entries.clear();

  /// Drop entries older than [media.auto_cleanup_after] (when enabled) and
  /// LRU-evict until under [media.cache_limit_gb].
  Future<void> enforceLimits() async {
    final runtime = SettingsRuntime.instance;

    // Prefer storage.media_ttl when enabled; else media.auto_cleanup_after.
    Duration? maxAge = await runtime.mediaTtlMaxAge();
    if (maxAge == null && await runtime.autoCleanup()) {
      maxAge = SettingsRuntime.parseTtlDuration(await runtime.autoCleanupAfter());
    }
    if (maxAge != null) {
      final cutoff = DateTime.now().subtract(maxAge);
      _entries.removeWhere((_, e) => e.createdAt.isBefore(cutoff));
    }

    final limitGb = await runtime.cacheLimitGb();
    if (limitGb <= 0) {
      _entries.clear();
      return;
    }
    final limitBytes = limitGb * 1024 * 1024 * 1024;
    if (totalBytes <= limitBytes) return;

    final ordered = _entries.entries.toList()
      ..sort((a, b) => a.value.lastAccess.compareTo(b.value.lastAccess));
    for (final e in ordered) {
      if (totalBytes <= limitBytes) break;
      _entries.remove(e.key);
    }
  }
}
