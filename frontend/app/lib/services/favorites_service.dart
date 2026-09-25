import 'package:uuid/uuid.dart';

import '../models/conversation.dart';
import '../models/favorite_item.dart';
import '../models/message.dart';
import '../utils/favorites_chat.dart';
import 'favorites_preferences_store.dart';
import 'favorites_store.dart';

class FavoritesService {
  FavoritesService({Uuid uuid = const Uuid()}) : _uuid = uuid;

  final Uuid _uuid;

  Future<bool> isEnabled() =>
      FavoritesPreferencesStore.instance.isChatEnabled();

  Future<void> setEnabled(bool enabled) =>
      FavoritesPreferencesStore.instance.setChatEnabled(enabled);

  Future<List<ChatMessage>> loadMessages() async {
    final items = await FavoritesStore.instance.loadAll();
    return items.map(FavoritesChat.toChatMessage).toList()
      ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
  }

  Future<List<ChatMessage>> add({
    required String conversationId,
    required String conversationTitle,
    required ChatMessage message,
    required String preview,
    required String senderLabel,
  }) async {
    await FavoritesStore.instance.save(
      FavoriteItem(
        id: _uuid.v4(),
        conversationId: conversationId,
        conversationTitle: conversationTitle,
        messageId: message.id,
        contentType: message.contentType,
        preview: preview,
        savedAt: DateTime.now(),
        senderUserId: message.senderUserId,
        senderLabel: senderLabel,
      ),
    );
    return loadMessages();
  }

  Future<List<ChatMessage>> remove(String favoriteId) async {
    await FavoritesStore.instance.remove(favoriteId);
    return loadMessages();
  }

  Conversation? visibleConversation({
    required bool enabled,
    required String? userId,
    required List<ChatMessage>? messages,
  }) {
    if (!enabled || userId == null || messages == null || messages.isEmpty) {
      return null;
    }
    return FavoritesChat.conversation(
      userId: userId,
      updatedAt: messages.last.createdAt,
    );
  }
}
