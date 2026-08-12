class ChatMessage {
  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.ciphertext,
    required this.contentType,
    required this.cryptoVersion,
    required this.createdAt,
    this.plaintext,
    this.decryptFailed = false,
    this.replyToMessageId,
    this.replyPreview,
    this.favoriteSourceConversationId,
    this.favoriteSourceMessageId,
    this.favoriteSourceTitle,
    this.favoriteSenderLabel,
    this.isSecret = false,
    this.systemKind,
    this.duressCode,
    this.ttlSeconds,
  });

  final String id;
  final String conversationId;
  final String senderUserId;
  final String? senderDeviceId;
  final String ciphertext; // opaque on the wire — see shared/README.md
  final String contentType;
  final String cryptoVersion;
  final DateTime createdAt;

  /// Filled in locally after decryption — never sent to/stored on the server.
  String? plaintext;
  bool decryptFailed;
  String? replyToMessageId;
  String? replyPreview;
  String? favoriteSourceConversationId;
  String? favoriteSourceMessageId;
  String? favoriteSourceTitle;
  String? favoriteSenderLabel;

  /// Parsed from E2E envelope (`secret: true`) — local UI only.
  bool isSecret;

  /// Client-only system marker inside plaintext JSON (`system` field).
  String? systemKind;

  /// Numeric duress signal code when `systemKind == duress`.
  int? duressCode;

  /// Optional per-message auto-delete TTL from E2E envelope (`ttl_seconds`).
  int? ttlSeconds;

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String,
    conversationId: json['conversation_id'] as String,
    senderUserId: json['sender_user_id'] as String,
    senderDeviceId: json['sender_device_id'] as String?,
    ciphertext: json['ciphertext'] as String,
    contentType: json['content_type'] as String,
    cryptoVersion: json['crypto_version'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}
