import '../models/message.dart';
import 'message_cache_store.dart';

class LocalMessageHistoryRestoreResult {
  const LocalMessageHistoryRestoreResult({
    required this.importedCount,
    required this.messagesByConversation,
  });

  final int importedCount;
  final Map<String, List<ChatMessage>> messagesByConversation;
}

/// Merges a bounded, decrypted local backup into the durable message cache.
///
/// Server state is deliberately not modified. Existing cached messages win on
/// identifier collisions, so importing an older backup cannot overwrite newer
/// local plaintext or delivery metadata.
class LocalMessageHistoryRestoreService {
  LocalMessageHistoryRestoreService(this._cache);

  static const _maxMessages = 40000;
  final MessageCacheStore _cache;

  Future<LocalMessageHistoryRestoreResult> restore({
    required String userId,
    required Set<String> knownConversationIds,
    required Iterable<ChatMessage> messages,
  }) async {
    final grouped = <String, List<ChatMessage>>{};
    var inspected = 0;
    for (final message in messages) {
      inspected++;
      if (inspected > _maxMessages) {
        throw const FormatException('Слишком много сообщений в копии');
      }
      if (!knownConversationIds.contains(message.conversationId)) continue;
      grouped.putIfAbsent(message.conversationId, () => []).add(message);
    }

    var imported = 0;
    final mergedByConversation = <String, List<ChatMessage>>{};
    for (final entry in grouped.entries) {
      final current = await _cache.loadConversation(userId, entry.key);
      final byId = {for (final message in current) message.id: message};
      for (final message in entry.value) {
        if (byId.containsKey(message.id)) continue;
        byId[message.id] = message;
        imported++;
      }
      final merged = byId.values.toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      await _cache.upsertMessages(userId, merged);
      mergedByConversation[entry.key] = merged;
    }
    return LocalMessageHistoryRestoreResult(
      importedCount: imported,
      messagesByConversation: mergedByConversation,
    );
  }
}
