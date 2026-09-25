class MessageReminder {
  const MessageReminder({
    required this.id,
    required this.conversationId,
    required this.messageId,
    required this.preview,
    required this.remindAt,
  });

  final String id;
  final String conversationId;
  final String messageId;
  final String preview;
  final DateTime remindAt;

  String encode() =>
      '$id|$conversationId|$messageId|${preview.replaceAll('|', '/')}|${remindAt.toIso8601String()}';

  factory MessageReminder.decode(String raw) {
    final parts = raw.split('|');
    if (parts.length < 5) throw FormatException('invalid reminder');
    return MessageReminder(
      id: parts[0],
      conversationId: parts[1],
      messageId: parts[2],
      preview: parts[3],
      remindAt: DateTime.parse(parts[4]),
    );
  }
}
