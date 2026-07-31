import '../models/conversation.dart';
import '../models/favorite_item.dart';
import '../models/message.dart';

/// Local virtual conversation for saved messages (not on the server).
class FavoritesChat {
  FavoritesChat._();

  static const id = '__local_favorites__';

  static bool isId(String? conversationId) => conversationId == id;

  static Conversation conversation({required String userId, DateTime? updatedAt}) {
    final now = updatedAt ?? DateTime.now();
    return Conversation(
      id: id,
      type: 'favorites',
      name: 'Избранное',
      participantUserIds: [userId],
      createdAt: now,
      updatedAt: now,
    );
  }

  static ChatMessage toChatMessage(FavoriteItem item) {
    return ChatMessage(
      id: item.id,
      conversationId: id,
      senderUserId: item.senderUserId,
      senderDeviceId: null,
      ciphertext: '',
      contentType: item.contentType,
      cryptoVersion: 'local-favorite',
      createdAt: item.savedAt,
      plaintext: item.preview,
      favoriteSourceConversationId: item.conversationId,
      favoriteSourceMessageId: item.messageId,
      favoriteSourceTitle: item.conversationTitle,
      favoriteSenderLabel: item.senderLabel,
    );
  }
}
