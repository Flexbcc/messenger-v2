import '../calls/call_signaling_service.dart';
import '../models/message.dart';
import 'surb_delivery_store.dart';

/// Pure message filtering rules shared by chat, search, and media views.
class MessageVisibilityService {
  const MessageVisibilityService();

  DateTime? _expiresAt(
    ChatMessage message, {
    required int? disappearingSeconds,
    required int? secretDisappearingSeconds,
  }) {
    final deadlines = <DateTime>[];
    final ttl = message.ttlSeconds;
    if (ttl != null && ttl > 0) {
      deadlines.add(message.createdAt.add(Duration(seconds: ttl)));
    }
    final conversationTtl = message.isSecret
        ? secretDisappearingSeconds
        : disappearingSeconds;
    if (conversationTtl != null && conversationTtl > 0) {
      deadlines.add(message.createdAt.add(Duration(seconds: conversationTtl)));
    }
    if (deadlines.isEmpty) return null;
    return deadlines.reduce(
      (left, right) => left.isBefore(right) ? left : right,
    );
  }

  bool isControlEnvelope(ChatMessage message) {
    if (message.contentType == 'read_receipt' ||
        message.contentType == 'login_approval_grant' ||
        message.contentType == 'sender_key_distribution' ||
        message.contentType == surbBundleContentType) {
      return true;
    }
    return CallSignalingService.isCallSignal(message.contentType);
  }

  List<ChatMessage> visible({
    required Iterable<ChatMessage> messages,
    required Set<String> locallyHiddenMessageIds,
    required bool secretSessionActive,
    required int? disappearingSeconds,
    required int? secretDisappearingSeconds,
    DateTime? now,
  }) {
    final evaluatedAt = now ?? DateTime.now();
    var result = messages.where(
      (message) =>
          !locallyHiddenMessageIds.contains(message.id) &&
          !isControlEnvelope(message),
    );
    if (!secretSessionActive) {
      result = result.where((message) => !message.isSecret);
    }
    return result.where((message) {
      final expiry = _expiresAt(
        message,
        disappearingSeconds: disappearingSeconds,
        secretDisappearingSeconds: secretDisappearingSeconds,
      );
      return expiry == null || expiry.isAfter(evaluatedAt);
    }).toList();
  }

  /// Earliest deadline that can change the currently visible message list.
  /// The chat screen uses this to rebuild at the actual expiry rather than
  /// waiting for an unrelated background refresh tick.
  DateTime? nextExpiry({
    required Iterable<ChatMessage> messages,
    required Set<String> locallyHiddenMessageIds,
    required bool secretSessionActive,
    required int? disappearingSeconds,
    required int? secretDisappearingSeconds,
    DateTime? now,
  }) {
    final evaluatedAt = now ?? DateTime.now();
    final current = visible(
      messages: messages,
      locallyHiddenMessageIds: locallyHiddenMessageIds,
      secretSessionActive: secretSessionActive,
      disappearingSeconds: disappearingSeconds,
      secretDisappearingSeconds: secretDisappearingSeconds,
      now: evaluatedAt,
    );
    DateTime? earliest;
    for (final message in current) {
      final expiry = _expiresAt(
        message,
        disappearingSeconds: disappearingSeconds,
        secretDisappearingSeconds: secretDisappearingSeconds,
      );
      if (expiry != null &&
          expiry.isAfter(evaluatedAt) &&
          (earliest == null || expiry.isBefore(earliest))) {
        earliest = expiry;
      }
    }
    return earliest;
  }

  List<ChatMessage> search(Iterable<ChatMessage> messages, String query) {
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) return [];
    return messages.where((message) {
      if (message.decryptFailed || message.plaintext == null) return false;
      if (message.contentType == 'text') {
        return message.plaintext!.toLowerCase().contains(normalizedQuery);
      }
      if (message.contentType == 'image') {
        return 'фото'.contains(normalizedQuery) ||
            normalizedQuery.contains('photo');
      }
      return false;
    }).toList();
  }

  List<ChatMessage> images(Iterable<ChatMessage> messages) => messages
      .where(
        (message) => message.contentType == 'image' && !message.decryptFailed,
      )
      .toList();
}
