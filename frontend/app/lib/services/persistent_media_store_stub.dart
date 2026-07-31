import 'dart:typed_data';
import 'dart:convert';

/// Non-web fallback. The product target is PWA; native builds keep a
/// process-local implementation until their filesystem adapter is required.
class PersistentMediaStore {
  PersistentMediaStore._();
  static final instance = PersistentMediaStore._();

  final Map<String, Map<String, Object>> _values = {};

  String _key(String userId, String mediaId) => '$userId::$mediaId';

  Future<void> putCiphertext(
    String userId,
    String mediaId,
    Uint8List bytes,
  ) async {
    _values[_key(userId, mediaId)] = {
      'user_id': userId,
      'media_id': mediaId,
      'bytes': bytes,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Future<Uint8List?> getCiphertext(String userId, String mediaId) async {
    return _values[_key(userId, mediaId)]?['bytes'] as Uint8List?;
  }

  Future<void> clearUser(String userId) async {
    _values.removeWhere((_, value) => value['user_id'] == userId);
  }

  Future<Map<String, String>> exportUser(String userId) async => {
    for (final value in _values.values)
      if (value['user_id'] == userId)
        value['media_id'] as String: base64Encode(value['bytes'] as Uint8List),
  };

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
    final now = DateTime.now().millisecondsSinceEpoch;
    if (maxAge != null) {
      _values.removeWhere(
        (_, value) =>
            value['user_id'] == userId &&
            now - (value['created_at'] as int) > maxAge.inMilliseconds,
      );
    }
    final entries =
        _values.entries
            .where((entry) => entry.value['user_id'] == userId)
            .toList()
          ..sort(
            (a, b) => (a.value['created_at'] as int).compareTo(
              b.value['created_at'] as int,
            ),
          );
    var total = entries.fold<int>(
      0,
      (sum, entry) => sum + (entry.value['bytes'] as Uint8List).length,
    );
    for (final entry in entries) {
      if (total <= maxBytes) break;
      total -= (entry.value['bytes'] as Uint8List).length;
      _values.remove(entry.key);
    }
  }
}
