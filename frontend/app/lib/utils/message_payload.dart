import 'dart:convert';

import '../models/message.dart';
import '../models/duress_policy.dart';

/// Client-side envelope inside E2E ciphertext (no server protocol change).
class MessagePayload {
  MessagePayload._();

  static const _version = 1;

  static String encodeDuress({required int code}) {
    return jsonEncode({
      'v': _version,
      'system': 'duress',
      'code': code,
      'ts': DateTime.now().toIso8601String(),
    });
  }

  static String encodeSystem({required String kind, required String body}) {
    return jsonEncode({
      'v': _version,
      'body': body,
      'system': kind,
    });
  }

  static String encodeText({
    required String body,
    bool secret = false,
    String? replyToMessageId,
    String? replyPreview,
    int? ttlSeconds,
  }) {
    final useJson = secret ||
        (replyToMessageId != null && replyToMessageId.isNotEmpty) ||
        ttlSeconds != null;
    if (!useJson) return body;
    return jsonEncode({
      'v': _version,
      'body': body,
      if (secret) 'secret': true,
      if (replyToMessageId != null && replyToMessageId.isNotEmpty) 'reply_to': replyToMessageId,
      if (replyPreview != null && replyPreview.isNotEmpty) 'reply_preview': replyPreview,
      if (ttlSeconds != null && ttlSeconds > 0) 'ttl_seconds': ttlSeconds,
    });
  }

  static String encodeJsonMap(
    Map<String, dynamic> map, {
    bool secret = false,
    int? ttlSeconds,
  }) {
    final out = Map<String, dynamic>.from(map);
    if (secret) out['secret'] = true;
    if (ttlSeconds != null && ttlSeconds > 0) out['ttl_seconds'] = ttlSeconds;
    return jsonEncode(out);
  }

  /// Parses structured plaintext into [ChatMessage] display fields.
  static void applyTo(ChatMessage message) {
    if (message.plaintext == null || message.decryptFailed) return;

    if (message.contentType == 'image' ||
        message.contentType == 'file' ||
        message.contentType == 'video') {
      _applyJsonFlags(message);
      return;
    }

    if (message.contentType != 'text') return;

    final raw = message.plaintext!.trim();
    if (!raw.startsWith('{')) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      message.isSecret = map['secret'] == true;
      _applyTtl(message, map);
      final system = map['system'];
      if (system is String && system.isNotEmpty) {
        message.systemKind = system;
      }
      final duressCode = map['code'];
      if (duressCode is int) {
        message.duressCode = duressCode;
      }
      if (map['v'] != _version) return;
      final body = map['body'];
      if (system == 'duress') {
        message.plaintext = DuressSignalLabels.forCode(message.duressCode ?? 0);
        return;
      }
      if (system == 'pin_duress_hint') {
        message.systemKind = 'duress';
        message.duressCode = 20;
        message.plaintext = DuressSignalLabels.forCode(20);
        return;
      }
      if (system == 'pin_duress_alert') {
        message.systemKind = 'duress';
        message.duressCode = 30;
        message.plaintext = DuressSignalLabels.forCode(30);
        return;
      }
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

  static void _applyJsonFlags(ChatMessage message) {
    final raw = message.plaintext!.trim();
    if (!raw.startsWith('{')) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      message.isSecret = map['secret'] == true;
      _applyTtl(message, map);
    } catch (_) {}
  }

  static void _applyTtl(ChatMessage message, Map<String, dynamic> map) {
    final ttl = map['ttl_seconds'];
    if (ttl is int && ttl > 0) {
      message.ttlSeconds = ttl;
    } else if (ttl is num && ttl > 0) {
      message.ttlSeconds = ttl.toInt();
    }
  }
}
