import 'package:flutter/material.dart';

import '../models/message.dart';
import 'message_format.dart';

const int messageGroupGapMinutes = 2;
const int messagePauseGapMinutes = 10;

bool isSameMessageGroup(ChatMessage current, ChatMessage previous) {
  if (current.senderUserId != previous.senderUserId) return false;
  final diff = current.createdAt.difference(previous.createdAt).inMinutes.abs();
  return diff < messageGroupGapMinutes;
}

bool shouldShowPauseSeparator(ChatMessage current, ChatMessage previous) {
  return current.createdAt.difference(previous.createdAt).inMinutes >=
      messagePauseGapMinutes;
}

class MessageGroupLayout {
  const MessageGroupLayout({
    required this.message,
    required this.isFirstInGroup,
    required this.isLastInGroup,
    required this.showGroupTime,
    required this.showDateSeparator,
    required this.showPauseSeparator,
  });

  final ChatMessage message;
  final bool isFirstInGroup;
  final bool isLastInGroup;
  final bool showGroupTime;
  final bool showDateSeparator;
  final bool showPauseSeparator;

  bool get isSingleInGroup => isFirstInGroup && isLastInGroup;
}

List<MessageGroupLayout> buildMessageLayouts(List<ChatMessage> messages) {
  final layouts = <MessageGroupLayout>[];
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    final previous = i > 0 ? messages[i - 1] : null;
    final next = i < messages.length - 1 ? messages[i + 1] : null;

    final showDateSeparator =
        previous == null || !isSameDay(previous.createdAt, message.createdAt);
    final showPauseSeparator =
        previous != null &&
        !showDateSeparator &&
        shouldShowPauseSeparator(message, previous);

    final firstInGroup =
        previous == null ||
        showDateSeparator ||
        showPauseSeparator ||
        !isSameMessageGroup(message, previous);

    final lastInGroup =
        next == null ||
        !isSameDay(message.createdAt, next.createdAt) ||
        shouldShowPauseSeparator(next, message) ||
        !isSameMessageGroup(next, message);

    layouts.add(
      MessageGroupLayout(
        message: message,
        isFirstInGroup: firstInGroup,
        isLastInGroup: lastInGroup,
        showGroupTime: lastInGroup,
        showDateSeparator: showDateSeparator,
        showPauseSeparator: showPauseSeparator,
      ),
    );
  }
  return layouts;
}

BorderRadius messageBubbleBorderRadius({
  required bool isMine,
  required bool isFirstInGroup,
  required bool isLastInGroup,
}) {
  const big = 18.0;
  const sm = 6.0;

  if (isFirstInGroup && isLastInGroup) {
    return BorderRadius.only(
      topLeft: const Radius.circular(big),
      topRight: const Radius.circular(big),
      bottomLeft: Radius.circular(isMine ? big : sm),
      bottomRight: Radius.circular(isMine ? sm : big),
    );
  }
  if (isFirstInGroup) {
    return BorderRadius.only(
      topLeft: const Radius.circular(big),
      topRight: const Radius.circular(big),
      bottomLeft: Radius.circular(isMine ? big : sm),
      bottomRight: const Radius.circular(sm),
    );
  }
  if (isLastInGroup) {
    return BorderRadius.only(
      topLeft: const Radius.circular(sm),
      topRight: const Radius.circular(sm),
      bottomLeft: Radius.circular(isMine ? big : sm),
      bottomRight: Radius.circular(isMine ? sm : big),
    );
  }
  return BorderRadius.only(
    topLeft: const Radius.circular(sm),
    topRight: const Radius.circular(sm),
    bottomLeft: Radius.circular(isMine ? sm : sm),
    bottomRight: const Radius.circular(sm),
  );
}
