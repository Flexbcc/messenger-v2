import 'dart:convert';
import 'dart:typed_data';

import '../crypto/auth_keypair.dart';
import '../models/conversation.dart';
import '../models/attachment_pointer.dart';
import '../models/message.dart';
import '../utils/message_payload.dart';
import 'api_client.dart';
import 'attachment_media_service.dart';
import 'media_quality.dart';
import 'message_encryption_service.dart';

typedef ConversationEncryptor =
    Future<EncryptedMessagePayload> Function(
      Conversation conversation,
      Uint8List plaintext,
    );

typedef SentAttachment = ({
  ChatMessage message,
  Uint8List plaintext,
  String mediaId,
});

/// Builds and transmits outbound chat messages without owning UI state.
class OutboundMessageService {
  const OutboundMessageService(this._api, this._attachments);

  static const _maxTextBytes = 64 * 1024;
  static const _maxReplyPreviewBytes = 4 * 1024;
  static const _maxAttachmentBytes = maxAttachmentPlaintextBytes;
  static final RegExp _mimePattern = RegExp(
    r'^[a-z0-9][a-z0-9!#$&^_.+-]{0,63}/[a-z0-9][a-z0-9!#$&^_.+-]{0,63}$',
  );
  static const _attachmentContentTypes = {'image', 'file', 'voice', 'video'};

  final ApiClient _api;
  final AttachmentMediaService _attachments;

  Future<ChatMessage> sendText({
    required Conversation conversation,
    required String clientMsgId,
    required String text,
    required bool secret,
    required int? ttlSeconds,
    required ConversationEncryptor encrypt,
    String? replyToMessageId,
    String? replyPreview,
  }) async {
    _validateClientMessageId(clientMsgId);
    final textBytes = utf8.encode(text);
    if (textBytes.isEmpty || textBytes.length > _maxTextBytes) {
      throw ArgumentError.value(text, 'text', 'message text size is invalid');
    }
    if (replyToMessageId != null &&
        (replyToMessageId.isEmpty || replyToMessageId.length > 64)) {
      throw ArgumentError.value(
        replyToMessageId,
        'replyToMessageId',
        'invalid reply message id',
      );
    }
    if (replyPreview != null &&
        utf8.encode(replyPreview).length > _maxReplyPreviewBytes) {
      throw ArgumentError.value(
        replyPreview,
        'replyPreview',
        'reply preview is too large',
      );
    }

    final wireBody = MessagePayload.encodeText(
      body: text,
      secret: secret,
      replyToMessageId: replyToMessageId,
      replyPreview: replyPreview,
      ttlSeconds: ttlSeconds,
    );
    final encrypted = await encrypt(
      conversation,
      Uint8List.fromList(utf8.encode(wireBody)),
    );
    final response = await _api.sendMessage(
      conversationId: conversation.id,
      ciphertext: encrypted.fallback,
      contentType: 'text',
      clientMsgId: clientMsgId,
      deviceEnvelopes: encrypted.deviceEnvelopes,
    );
    return ChatMessage.fromJson(response)
      ..plaintext = text
      ..replyToMessageId = replyToMessageId
      ..replyPreview = replyPreview
      ..isSecret = secret
      ..ttlSeconds = ttlSeconds;
  }

  Future<SentAttachment> sendAttachment({
    required Conversation conversation,
    required String clientMsgId,
    required Uint8List bytes,
    required String filename,
    required String mime,
    required String contentType,
    required bool secret,
    required int? ttlSeconds,
    required String userId,
    required AuthKeyPair authKeyPair,
    required ConversationEncryptor encrypt,
  }) async {
    _validateClientMessageId(clientMsgId);
    _validateAttachment(bytes, filename, mime, contentType);

    var plaintext = bytes;
    if (contentType == 'image') {
      plaintext = await MediaQuality.prepareImage(bytes);
      if (plaintext.isEmpty || plaintext.length > _maxAttachmentBytes) {
        throw StateError('prepared image size is invalid');
      }
    }

    final upload = await _attachments.encryptAndUpload(
      plaintext,
      filename: filename,
      mime: mime,
      userId: userId,
      authKeyPair: authKeyPair,
    );
    final pointerJson = MessagePayload.encodeJsonMap(
      {...upload.pointer, 'media_id': upload.mediaId},
      secret: secret,
      ttlSeconds: ttlSeconds,
    );
    final encrypted = await encrypt(
      conversation,
      Uint8List.fromList(utf8.encode(pointerJson)),
    );
    final response = await _api.sendMessage(
      conversationId: conversation.id,
      ciphertext: encrypted.fallback,
      contentType: contentType,
      clientMsgId: clientMsgId,
      deviceEnvelopes: encrypted.deviceEnvelopes,
    );
    final message = ChatMessage.fromJson(response)
      ..plaintext = pointerJson
      ..ttlSeconds = ttlSeconds;
    MessagePayload.applyTo(message);
    return (message: message, plaintext: plaintext, mediaId: upload.mediaId);
  }

  static void _validateClientMessageId(String value) {
    if (value.isEmpty || value.length > 64) {
      throw ArgumentError.value(value, 'clientMsgId', 'invalid message id');
    }
  }

  static void _validateAttachment(
    Uint8List bytes,
    String filename,
    String mime,
    String contentType,
  ) {
    if (bytes.isEmpty || bytes.length > _maxAttachmentBytes) {
      throw ArgumentError('attachment size is invalid');
    }
    if (filename.isEmpty ||
        utf8.encode(filename).length > 255 ||
        filename.contains('/') ||
        filename.contains('\\') ||
        filename.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
      throw ArgumentError.value(filename, 'filename', 'invalid filename');
    }
    if (!_mimePattern.hasMatch(mime.toLowerCase())) {
      throw ArgumentError.value(mime, 'mime', 'invalid MIME type');
    }
    if (!_attachmentContentTypes.contains(contentType)) {
      throw ArgumentError.value(
        contentType,
        'contentType',
        'invalid attachment content type',
      );
    }
  }
}
