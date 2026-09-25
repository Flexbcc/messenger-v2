import 'dart:async';

import '../models/message.dart';
import '../utils/message_payload.dart';
import 'debug_log.dart';
import 'secret_chat_preferences_store.dart';

/// Owns the in-memory lifetime of unlocked secret-chat plaintext.
class SecretSessionManager {
  final Set<String> _active = {};
  final Map<String, Timer> _timers = {};
  final Map<String, String> _plaintextVault = {};

  bool isActive(String conversationId) => _active.contains(conversationId);

  bool activate(String conversationId, Iterable<ChatMessage> messages) {
    _active.add(conversationId);
    return unseal(messages);
  }

  bool deactivate(String conversationId, Iterable<ChatMessage> messages) {
    if (!_active.remove(conversationId)) return false;
    _timers.remove(conversationId)?.cancel();
    for (final message in messages) {
      sealIfInactive(message);
    }
    return true;
  }

  bool sealIfInactive(ChatMessage message) {
    if (!message.isSecret || isActive(message.conversationId)) return false;
    final body = message.plaintext;
    if (body == null || body.isEmpty) return false;
    _plaintextVault[message.id] = body;
    message.plaintext = null;
    return true;
  }

  bool unseal(Iterable<ChatMessage> messages) {
    var changed = false;
    for (final message in messages) {
      if (!message.isSecret) continue;
      final stored = _plaintextVault.remove(message.id);
      if (stored == null) continue;
      message.plaintext = stored;
      message.decryptFailed = false;
      MessagePayload.applyTo(message);
      changed = true;
    }
    return changed;
  }

  void touch(String conversationId, void Function() onExpired) {
    if (!isActive(conversationId)) return;
    _scheduleTimeout(conversationId, onExpired);
  }

  void scheduleTimeout(String conversationId, void Function() onExpired) {
    _scheduleTimeout(conversationId, onExpired);
  }

  Future<void> _scheduleTimeout(
    String conversationId,
    void Function() onExpired,
  ) async {
    _timers.remove(conversationId)?.cancel();
    late final int minutes;
    try {
      minutes = await SecretChatPreferencesStore.instance
          .sessionTimeoutMinutes();
    } catch (error) {
      DebugLog.instance.error(
        'secret-chat',
        'Unable to schedule secret session timeout',
        error,
      );
      onExpired();
      return;
    }
    if (!isActive(conversationId)) return;
    _timers[conversationId] = Timer(Duration(minutes: minutes), onExpired);
  }

  List<String> activeConversationIds() => _active.toList(growable: false);

  void clearPlaintext() => _plaintextVault.clear();

  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _active.clear();
    _plaintextVault.clear();
  }
}
