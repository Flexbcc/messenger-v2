/// Per-chat draft — text, reply context, attachment metadata.
class ChatDraft {
  const ChatDraft({
    this.text = '',
    this.replyToMessageId,
    this.replyPreview,
    this.attachmentName,
    this.attachmentMime,
    this.updatedAt,
  });

  final String text;
  final String? replyToMessageId;
  final String? replyPreview;
  final String? attachmentName;
  final String? attachmentMime;
  final DateTime? updatedAt;

  bool get isEmpty =>
      text.trim().isEmpty && replyToMessageId == null && attachmentName == null;

  String encode() => [
    text.replaceAll('|', '/'),
    replyToMessageId ?? '',
    (replyPreview ?? '').replaceAll('|', '/'),
    attachmentName ?? '',
    attachmentMime ?? '',
    updatedAt?.toIso8601String() ?? '',
  ].join('|');

  factory ChatDraft.decode(String raw) {
    final parts = raw.split('|');
    if (parts.length < 6) return const ChatDraft();
    return ChatDraft(
      text: parts[0],
      replyToMessageId: parts[1].isEmpty ? null : parts[1],
      replyPreview: parts[2].isEmpty ? null : parts[2],
      attachmentName: parts[3].isEmpty ? null : parts[3],
      attachmentMime: parts[4].isEmpty ? null : parts[4],
      updatedAt: parts[5].isEmpty ? null : DateTime.tryParse(parts[5]),
    );
  }

  ChatDraft copyWith({
    String? text,
    String? replyToMessageId,
    String? replyPreview,
    String? attachmentName,
    String? attachmentMime,
    DateTime? updatedAt,
    bool clearReply = false,
    bool clearAttachment = false,
  }) {
    return ChatDraft(
      text: text ?? this.text,
      replyToMessageId: clearReply
          ? null
          : (replyToMessageId ?? this.replyToMessageId),
      replyPreview: clearReply ? null : (replyPreview ?? this.replyPreview),
      attachmentName: clearAttachment
          ? null
          : (attachmentName ?? this.attachmentName),
      attachmentMime: clearAttachment
          ? null
          : (attachmentMime ?? this.attachmentMime),
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
