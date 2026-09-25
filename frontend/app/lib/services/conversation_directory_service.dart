import '../models/conversation.dart';
import '../utils/favorites_chat.dart';
import '../utils/user_id.dart';
import 'api_client.dart';
import 'conversation_reachability_service.dart';
import 'debug_log.dart';

/// Owns conversation identity, lookup and reachability rules.
///
/// Keeping these rules outside the application controller prevents UI state
/// orchestration from becoming the authority for user-id validation.
class ConversationDirectoryService {
  ConversationDirectoryService(this._api, this._reachability);

  final ApiClient _api;
  final ConversationReachabilityService _reachability;

  final Map<String, bool> reachableByConversation = {};
  final Map<String, String?> errorByConversation = {};

  String labelFor(
    String userId, {
    required String? currentUserId,
    required Map<String, String> knownDisplayNames,
  }) {
    if (userId == currentUserId) return 'Вы';
    final cached = knownDisplayNames[userId];
    if (cached != null) return cached;
    final prefixLen = userId.length < 8 ? userId.length : 8;
    return '${userId.substring(0, prefixLen)}…';
  }

  String titleFor(
    Conversation conversation, {
    required String? currentUserId,
    required Map<String, String> knownDisplayNames,
  }) {
    if (FavoritesChat.isId(conversation.id)) return 'Избранное';
    final name = conversation.name;
    if (name != null && name.isNotEmpty) return name;
    return conversation.participantUserIds
        .where((id) => id != currentUserId)
        .map(
          (id) => labelFor(
            id,
            currentUserId: currentUserId,
            knownDisplayNames: knownDisplayNames,
          ),
        )
        .join(', ');
  }

  String? directPeerUserId(
    Conversation conversation, {
    required String? currentUserId,
  }) {
    if (conversation.isGroup || currentUserId == null) return null;
    for (final id in conversation.participantUserIds) {
      if (id != currentUserId) return id;
    }
    return null;
  }

  Conversation? findDirectConversation(
    Iterable<Conversation> conversations, {
    required String peerUserId,
    required String? currentUserId,
  }) {
    if (currentUserId == null) return null;
    for (final conversation in conversations) {
      if (conversation.isGroup) continue;
      final participants = conversation.participantUserIds.toSet();
      if (participants.length == 2 &&
          participants.contains(currentUserId) &&
          participants.contains(peerUserId)) {
        return conversation;
      }
    }
    return null;
  }

  Future<String?> validateReachability(
    Conversation conversation, {
    required String? currentUserId,
  }) async {
    if (conversation.isGroup) {
      reachableByConversation[conversation.id] = true;
      errorByConversation[conversation.id] = null;
      return null;
    }
    final peer = directPeerUserId(conversation, currentUserId: currentUserId);
    if (peer == null) {
      reachableByConversation[conversation.id] = false;
      errorByConversation[conversation.id] = 'Нет собеседника в чате';
      return null;
    }
    if (!isValidUserIdFormat(peer)) {
      reachableByConversation[conversation.id] = false;
      errorByConversation[conversation.id] =
          'Некорректный User ID собеседника: $peer';
      DebugLog.instance.error('chat', 'invalid peer id format', peer);
      return null;
    }

    final result = await _reachability.check(peer);
    switch (result.status) {
      case ReachabilityStatus.reachable:
        reachableByConversation[conversation.id] = true;
        errorByConversation[conversation.id] = null;
        return peer;
      case ReachabilityStatus.notFound:
        reachableByConversation[conversation.id] = false;
        errorByConversation[conversation.id] = result.detail;
      case ReachabilityStatus.transientFailure:
        reachableByConversation[conversation.id] ??= true;
        errorByConversation[conversation.id] = null;
    }
    return null;
  }

  bool isReachable(Conversation conversation) {
    if (FavoritesChat.isId(conversation.id) || conversation.isGroup) {
      return true;
    }
    return reachableByConversation[conversation.id] ?? true;
  }

  Future<String> verifyPeerUserId(
    String rawUserId, {
    required String? currentUserId,
  }) async {
    final id = normalizeUserId(rawUserId);
    if (!isValidUserIdFormat(id)) {
      throw ArgumentError(userIdFormatHint());
    }
    if (id == currentUserId) {
      throw ArgumentError('Нельзя начать чат с самим собой');
    }
    try {
      await _api.getPreKeyBundle(id);
    } on ApiException catch (error) {
      if (error.statusCode == 404) {
        throw ArgumentError(
          'Пользователь $id не найден на сервере. '
          'Собеседник должен зарегистрироваться, затем скопировать User ID '
          'из Настройки → Аккаунт.',
        );
      }
      rethrow;
    }
    return id;
  }
}
