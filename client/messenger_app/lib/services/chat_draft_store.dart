import '../models/chat_draft.dart';
import 'local_settings_store.dart';

/// Persists chat drafts locally (survives app restart).
class ChatDraftStore {
  ChatDraftStore._();
  static final instance = ChatDraftStore._();

  final _store = LocalSettingsStore();
  final _cache = <String, ChatDraft>{};

  Future<ChatDraft> get(String conversationId) async {
    if (_cache.containsKey(conversationId)) return _cache[conversationId]!;
    final raw = await _store.getString('chat_draft_$conversationId', '');
    final draft = raw.isEmpty ? const ChatDraft() : ChatDraft.decode(raw);
    _cache[conversationId] = draft;
    return draft;
  }

  Future<void> save(String conversationId, ChatDraft draft) async {
    if (draft.isEmpty) {
      await clear(conversationId);
      return;
    }
    final withTime = draft.copyWith(updatedAt: DateTime.now());
    _cache[conversationId] = withTime;
    await _store.setString('chat_draft_$conversationId', withTime.encode());
  }

  Future<void> clear(String conversationId) async {
    _cache.remove(conversationId);
    await _store.setString('chat_draft_$conversationId', '');
  }

  String previewFor(String conversationId) {
    final draft = _cache[conversationId];
    if (draft == null || draft.isEmpty) return '';
    final parts = <String>[];
    if (draft.replyPreview != null) parts.add('↩ ${draft.replyPreview}');
    if (draft.attachmentName != null) parts.add('📎 ${draft.attachmentName}');
    if (draft.text.trim().isNotEmpty) parts.add(draft.text.trim());
    return parts.join(' · ');
  }
}
