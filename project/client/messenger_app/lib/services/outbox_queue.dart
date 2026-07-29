import 'dart:convert';

import 'local_settings_store.dart';

/// Persisted outbox for messages that failed to send due to network unavailability.
///
/// Each entry stores enough to re-encrypt and re-send when connectivity is restored.
/// Note: we store plaintext here (encrypted at rest by OS via SecureStorage of
/// the encryption key; the message itself is short-lived — removed on send).
///
/// Entry format (JSON):
/// {
///   "id": "<clientMsgId>",
///   "conversationId": "<conv_id>",
///   "text": "<plaintext>",
///   "replyToMessageId": "<id>?",
///   "replyPreview": "<text>?",
///   "secret": bool,
///   "ttlSeconds": int?,
///   "queuedAt": "<iso8601>"
/// }
class OutboxQueue {
  OutboxQueue._();
  static final instance = OutboxQueue._();

  static const _queueKey = 'outbox_queue_v1';

  final _store = LocalSettingsStore();

  /// In-memory list of queued entries (loaded from storage on init).
  final List<OutboxEntry> _entries = [];

  List<OutboxEntry> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;
  bool get isNotEmpty => _entries.isNotEmpty;

  Future<void> load() async {
    final raw = await _store.getString(_queueKey, '');
    if (raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      _entries
        ..clear()
        ..addAll(list.map((e) => OutboxEntry.fromJson(e as Map<String, dynamic>)));
    } catch (_) {
      _entries.clear();
    }
  }

  Future<void> enqueue(OutboxEntry entry) async {
    _entries.add(entry);
    await _persist();
  }

  Future<void> remove(String clientMsgId) async {
    _entries.removeWhere((e) => e.id == clientMsgId);
    await _persist();
  }

  Future<void> clear() async {
    _entries.clear();
    await _persist();
  }

  Future<void> _persist() async {
    final json = jsonEncode(_entries.map((e) => e.toJson()).toList());
    await _store.setString(_queueKey, json);
  }
}

class OutboxEntry {
  OutboxEntry({
    required this.id,
    required this.conversationId,
    required this.text,
    this.replyToMessageId,
    this.replyPreview,
    required this.secret,
    this.ttlSeconds,
    DateTime? queuedAt,
  }) : queuedAt = queuedAt ?? DateTime.now();

  final String id;
  final String conversationId;
  final String text;
  final String? replyToMessageId;
  final String? replyPreview;
  final bool secret;
  final int? ttlSeconds;
  final DateTime queuedAt;

  factory OutboxEntry.fromJson(Map<String, dynamic> json) => OutboxEntry(
        id: json['id'] as String,
        conversationId: json['conversationId'] as String,
        text: json['text'] as String,
        replyToMessageId: json['replyToMessageId'] as String?,
        replyPreview: json['replyPreview'] as String?,
        secret: json['secret'] as bool? ?? false,
        ttlSeconds: json['ttlSeconds'] as int?,
        queuedAt: DateTime.tryParse(json['queuedAt'] as String? ?? '') ?? DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'conversationId': conversationId,
        'text': text,
        if (replyToMessageId != null) 'replyToMessageId': replyToMessageId,
        if (replyPreview != null) 'replyPreview': replyPreview,
        'secret': secret,
        if (ttlSeconds != null) 'ttlSeconds': ttlSeconds,
        'queuedAt': queuedAt.toIso8601String(),
      };
}
