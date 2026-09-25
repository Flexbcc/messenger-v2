import 'model_parsing.dart';

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
    id: requiredBoundedString(json, 'id', maxLength: 128),
    conversationId: requiredBoundedString(
      json,
      'conversation_id',
      maxLength: 128,
    ),
    senderUserId: requiredBoundedString(json, 'sender_user_id', maxLength: 128),
    senderDeviceId: optionalBoundedString(
      json,
      'sender_device_id',
      maxLength: 128,
    ),
    ciphertext: requiredBoundedString(
      json,
      'ciphertext',
      maxLength: 192 * 1024,
    ),
    contentType: requiredBoundedString(json, 'content_type', maxLength: 20),
    cryptoVersion: requiredBoundedString(json, 'crypto_version', maxLength: 30),
    createdAt: requiredDateTime(json, 'created_at'),
  );

  factory ChatMessage.fromRealtimeEnvelope(Map<String, dynamic> envelope) {
    return ChatMessage.fromJson({
      'id': envelope['packet_id'],
      'conversation_id': envelope['conversation_id'],
      'sender_user_id': envelope['sender_user_id'],
      'sender_device_id': envelope['sender_device_id'],
      'ciphertext': envelope['ciphertext'],
      'content_type': envelope['content_type'] ?? 'text',
      'crypto_version': envelope['crypto_version'] ?? 'signal-v1',
      'created_at': envelope['created_at'],
    });
  }
}
