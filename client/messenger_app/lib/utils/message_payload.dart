import 'dart:convert';

import '../models/message.dart';

/// Client-side text envelope inside E2E ciphertext (no server protocol change).
class MessagePayload {
  MessagePayload._();

  static const _version = 1;

  static String encodeText({
    required String body,
    String? replyToMessageId,
    String? replyPreview,
  }) {
    if (replyToMessageId == null || replyToMessageId.isEmpty) return body;
    return jsonEncode({
      'v': _version,
      'body': body,
      'reply_to': replyToMessageId,
      'reply_preview': replyPreview ?? '',
    });
  }

  /// Parses structured plaintext into [ChatMessage] display fields.
  static void applyTo(ChatMessage message) {
    if (message.contentType != 'text' || message.plaintext == null || message.decryptFailed) return;
    final raw = message.plaintext!.trim();
    if (!raw.startsWith('{')) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['v'] != _version) return;
      final body = map['body'];
      if (body is! String) return;
      final replyTo = map['reply_to'] as String?;
      final replyPreview = map['reply_preview'] as String?;
      message.plaintext = body;
      message.replyToMessageId = replyTo != null && replyTo.isNotEmpty ? replyTo : null;
      message.replyPreview = replyPreview != null && replyPreview.isNotEmpty ? replyPreview : null;
    } catch (_) {
      // Plain text that happens to start with "{" — leave as-is.
    }
  }
}
