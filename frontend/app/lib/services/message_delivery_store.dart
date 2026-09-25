import '../models/message_delivery_info.dart';
import 'local_settings_store.dart';

/// Per-message outbound status and peer read watermarks (local).
class MessageDeliveryStore {
  MessageDeliveryStore._();
  static final instance = MessageDeliveryStore._();

  final _store = LocalSettingsStore();
  final _memory = <String, MessageDeliveryInfo>{};
  final _peerReadUntil = <String, DateTime>{};

  MessageDeliveryInfo? infoFor(String messageId) => _memory[messageId];

  DateTime? peerReadUntil(String conversationId) =>
      _peerReadUntil[conversationId];

  Future<void> setStatus(
    String messageId,
    MessageDeliveryStatus status, {
    String? error,
  }) async {
    final info = MessageDeliveryInfo(
      status: status,
      error: error,
      updatedAt: DateTime.now(),
    );
    _memory[messageId] = info;
    await _store.setString(
      'msg_delivery_$messageId',
      '${status.name}|${error ?? ''}|${info.updatedAt!.toIso8601String()}',
    );
  }

  Future<void> loadForMessage(String messageId) async {
    if (_memory.containsKey(messageId)) return;
    final raw = await _store.getString('msg_delivery_$messageId', '');
    if (raw.isEmpty) return;
    final parts = raw.split('|');
    if (parts.length < 3) return;
    final status = MessageDeliveryStatus.values.firstWhere(
      (s) => s.name == parts[0],
      orElse: () => MessageDeliveryStatus.sent,
    );
    _memory[messageId] = MessageDeliveryInfo(
      status: status,
      error: parts[1].isEmpty ? null : parts[1],
      updatedAt: DateTime.tryParse(parts[2]),
    );
  }

  Future<void> setPeerReadUntil(String conversationId, DateTime until) async {
    final prev = _peerReadUntil[conversationId];
    if (prev != null && !until.isAfter(prev)) return;
    _peerReadUntil[conversationId] = until;
    await _store.setInt(
      'peer_read_ms_$conversationId',
      until.millisecondsSinceEpoch,
    );
  }

  Future<void> loadPeerRead(String conversationId) async {
    if (_peerReadUntil.containsKey(conversationId)) return;
    final ms = await _store.getInt('peer_read_ms_$conversationId', 0);
    if (ms > 0) {
      _peerReadUntil[conversationId] = DateTime.fromMillisecondsSinceEpoch(ms);
    }
  }

  Future<void> clearConversation(String conversationId) async {
    _peerReadUntil.remove(conversationId);
    await _store.setInt('peer_read_ms_$conversationId', 0);
  }
}
