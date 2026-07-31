/// Locally queued message to send at [sendAt].
class ScheduledMessage {
  const ScheduledMessage({
    required this.id,
    required this.conversationId,
    required this.text,
    required this.sendAt,
    required this.createdAt,
    this.replyToMessageId,
    this.replyPreview,
  });

  final String id;
  final String conversationId;
  final String text;
  final DateTime sendAt;
  final DateTime createdAt;
  final String? replyToMessageId;
  final String? replyPreview;

  String encode() => [
        id,
        conversationId,
        text.replaceAll('|', '/'),
        sendAt.toIso8601String(),
        createdAt.toIso8601String(),
        replyToMessageId ?? '',
        (replyPreview ?? '').replaceAll('|', '/'),
      ].join('|');

  factory ScheduledMessage.decode(String raw) {
    final parts = raw.split('|');
    if (parts.length < 5) {
      throw FormatException('invalid scheduled message');
    }
    return ScheduledMessage(
      id: parts[0],
      conversationId: parts[1],
      text: parts[2],
      sendAt: DateTime.parse(parts[3]),
      createdAt: DateTime.parse(parts[4]),
      replyToMessageId: parts.length > 5 && parts[5].isNotEmpty ? parts[5] : null,
      replyPreview: parts.length > 6 && parts[6].isNotEmpty ? parts[6] : null,
    );
  }
}
