class FavoriteItem {
  const FavoriteItem({
    required this.id,
    required this.conversationId,
    required this.conversationTitle,
    required this.messageId,
    required this.contentType,
    required this.preview,
    required this.savedAt,
    this.senderUserId = '',
    this.senderLabel = '',
  });

  final String id;
  final String conversationId;
  final String conversationTitle;
  final String messageId;
  final String contentType;
  final String preview;
  final DateTime savedAt;
  final String senderUserId;
  final String senderLabel;

  String encode() => [
        id,
        conversationId,
        conversationTitle.replaceAll('|', '/'),
        messageId,
        contentType,
        preview.replaceAll('|', '/'),
        savedAt.toIso8601String(),
        senderUserId,
        senderLabel.replaceAll('|', '/'),
      ].join('|');

  factory FavoriteItem.decode(String raw) {
    final parts = raw.split('|');
    if (parts.length < 7) throw FormatException('invalid favorite');
    return FavoriteItem(
      id: parts[0],
      conversationId: parts[1],
      conversationTitle: parts[2],
      messageId: parts[3],
      contentType: parts[4],
      preview: parts[5],
      savedAt: DateTime.parse(parts[6]),
      senderUserId: parts.length > 7 ? parts[7] : '',
      senderLabel: parts.length > 8 ? parts[8] : '',
    );
  }
}
