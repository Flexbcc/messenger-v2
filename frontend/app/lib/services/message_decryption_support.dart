import '../models/conversation.dart';
import '../models/message.dart';
import '../utils/message_payload.dart';

/// Stateless cache/replay helpers used around Signal's single-use decryptors.
abstract final class MessageDecryptionSupport {
  static String queueKey(
    ChatMessage message, {
    required Conversation? conversation,
  }) {
    if (conversation?.isGroup == true) {
      return 'group:${message.conversationId}:${message.senderUserId}';
    }
    return 'direct:${message.senderUserId}';
  }

  static Map<String, ChatMessage> buildPlaintextIndex(
    Iterable<ChatMessage> diskCached,
    Iterable<ChatMessage> memoryCached,
  ) {
    final index = <String, ChatMessage>{};
    for (final message in [...diskCached, ...memoryCached]) {
      if (message.plaintext != null &&
          message.plaintext!.isNotEmpty &&
          !message.decryptFailed) {
        index[message.id] = message;
      }
    }
    return index;
  }

  static bool applyPlaintext(ChatMessage target, ChatMessage source) {
    if (source.plaintext == null || source.plaintext!.isEmpty) return false;
    target.plaintext = source.plaintext;
    target.replyToMessageId = source.replyToMessageId;
    target.replyPreview = source.replyPreview;
    target.decryptFailed = false;
    MessagePayload.applyTo(target);
    return true;
  }

  static bool isDuplicateDecryptError(Object error) =>
      error.toString().contains('DuplicateMessageException');
}
