/// Key Transparency Service (Task #67).
///
/// Клиент запрашивает историю смены ключей контакта и предупреждает
/// если identity key изменился неожиданно (признак MITM или компрометации).
///
/// Хранит последний проверенный entry_id и fingerprint для каждого user_id
/// чтобы при следующей проверке запрашивать только новые записи.
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';

class KeyChangeWarning {
  const KeyChangeWarning({
    required this.userId,
    required this.oldFingerprint,
    required this.newFingerprint,
    required this.eventType,
    required this.at,
  });

  final String userId;
  final String oldFingerprint;
  final String newFingerprint;
  final String eventType;
  final DateTime at;
}

class KeyTransparencyService {
  KeyTransparencyService._();
  static final instance = KeyTransparencyService._();

  static const _prefixLastId = 'ktl_last_id_';
  static const _prefixLastFp = 'ktl_last_fp_';

  /// Проверить key log для [userId]. Возвращает [KeyChangeWarning] если ключ
  /// изменился с момента последней проверки, иначе null.
  ///
  /// Best-effort: не бросает исключений — ошибки сети логируются и игнорируются.
  Future<KeyChangeWarning?> checkForKeyChange(ApiClient api, String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastId = prefs.getString('$_prefixLastId$userId');
      final lastFp = prefs.getString('$_prefixLastFp$userId');

      final result = await api.getUserKeyLog(userId, sinceId: lastId, limit: 50);
      final entries = (result['entries'] as List?) ?? [];
      final chainErrors = (result['chain_errors'] as List?) ?? [];

      if (chainErrors.isNotEmpty) {
        // Chain integrity violation — серьёзная проблема
        return KeyChangeWarning(
          userId: userId,
          oldFingerprint: lastFp ?? '',
          newFingerprint: 'CHAIN_ERROR',
          eventType: 'chain_integrity_violation',
          at: DateTime.now(),
        );
      }

      if (entries.isEmpty) return null;

      // Сохраняем последний проверенный entry
      final last = entries.last as Map<String, dynamic>;
      final newFp = last['identity_key_fingerprint'] as String?;
      final newId = last['id'] as String?;

      if (newId != null) {
        await prefs.setString('$_prefixLastId$userId', newId);
      }
      if (newFp != null) {
        await prefs.setString('$_prefixLastFp$userId', newFp);
      }

      // Если у нас уже был записан fingerprint и он отличается — предупреждение
      if (lastFp != null && newFp != null && lastFp != newFp) {
        final eventType = last['event_type'] as String? ?? 'identity_key_changed';
        final createdAt = last['created_at'] as String?;
        return KeyChangeWarning(
          userId: userId,
          oldFingerprint: lastFp,
          newFingerprint: newFp,
          eventType: eventType,
          at: createdAt != null ? DateTime.tryParse(createdAt) ?? DateTime.now() : DateTime.now(),
        );
      }

      return null;
    } catch (e) {
      // Non-fatal — key log недоступен, продолжаем без проверки
      return null;
    }
  }

  /// Сбросить кэш для [userId] (например после верификации safety number).
  Future<void> resetForUser(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefixLastId$userId');
    await prefs.remove('$_prefixLastFp$userId');
  }

  /// Сбросить весь кэш (при logout).
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where(
      (k) => k.startsWith(_prefixLastId) || k.startsWith(_prefixLastFp),
    );
    for (final k in keys) {
      await prefs.remove(k);
    }
  }
}
