import '../models/message.dart';
import '../models/conversation.dart';

/// Pure ordering and visibility rules for conversation lists.
///
/// UI orchestration owns the sets and messages; this service owns how those
/// inputs become stable visible/search/hidden lists.
class ConversationListService {
  const ConversationListService();

  DateTime activity(
    Conversation conversation,
    Map<String, List<ChatMessage>> messagesByConversation,
  ) {
    final messages = messagesByConversation[conversation.id];
    if (messages != null && messages.isNotEmpty) return messages.last.createdAt;
    return conversation.updatedAt;
  }

  void sortInPlace(
    List<Conversation> conversations,
    Map<String, List<ChatMessage>> messagesByConversation,
  ) {
    conversations.sort(
      (left, right) => activity(
        right,
        messagesByConversation,
      ).compareTo(activity(left, messagesByConversation)),
    );
  }

  List<Conversation> visibleSorted({
    required Iterable<Conversation> conversations,
    required Map<String, List<ChatMessage>> messagesByConversation,
    required Set<String> locallyHiddenIds,
    required Set<String> secretHiddenIds,
  }) {
    final result = conversations
        .where(
          (conversation) =>
              !locallyHiddenIds.contains(conversation.id) &&
              !secretHiddenIds.contains(conversation.id),
        )
        .toList();
    sortInPlace(result, messagesByConversation);
    return result;
  }

  List<Conversation> secretHiddenSorted({
    required Iterable<Conversation> conversations,
    required Map<String, List<ChatMessage>> messagesByConversation,
    required Set<String> secretHiddenIds,
    required bool sortByName,
    required String Function(Conversation) titleFor,
  }) {
    final result = conversations
        .where((conversation) => secretHiddenIds.contains(conversation.id))
        .toList();
    if (sortByName) {
      result.sort((left, right) => titleFor(left).compareTo(titleFor(right)));
    } else {
      sortInPlace(result, messagesByConversation);
    }
    return result;
  }

  List<Conversation> matchingSearch({
    required String query,
    required Iterable<Conversation> visible,
    required Iterable<Conversation> additionallySearchable,
    required String Function(Conversation) titleFor,
  }) {
    final byId = <String, Conversation>{
      for (final conversation in visible) conversation.id: conversation,
    };
    for (final conversation in additionallySearchable) {
      byId.putIfAbsent(conversation.id, () => conversation);
    }
    final pool = byId.values.toList(growable: false);
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return pool;
    return pool
        .where(
          (conversation) =>
              titleFor(conversation).toLowerCase().contains(normalized),
        )
        .toList(growable: false);
  }
}
