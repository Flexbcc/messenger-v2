part of 'app_controller.dart';

extension AppControllerSecretSessionOperations on AppController {
  bool isSecretSessionActive(String conversationId) =>
      _secretSessions.isActive(conversationId);

  Future<bool> tryActivateSecretSession(
    String conversationId,
    String password,
  ) async {
    if (AppPrivacySession.instance.isInDecoyMode) return false;
    if (!await PinSecurity.isRealPinConfigured()) return false;
    if (!await SecretChatSecurity.isConfigured()) return false;
    if (!await SecretChatSecurity.verify(password)) return false;
    activateSecretSession(conversationId);
    return true;
  }

  void activateSecretSession(String conversationId) {
    if (AppPrivacySession.instance.isInDecoyMode) return;
    final list = messagesByConversation[conversationId] ?? const [];
    final changed = _secretSessions.activate(conversationId, list);
    if (changed) _persistSecretConversation(list);
    _secretSessions.scheduleTimeout(
      conversationId,
      () => deactivateSecretSession(conversationId),
    );
    _notifyStateChanged();
  }

  void deactivateSecretSession(String conversationId) {
    final list = messagesByConversation[conversationId] ?? const [];
    if (!_secretSessions.deactivate(conversationId, list)) return;
    _persistSecretConversation(list);
    _notifyStateChanged();
  }

  void _sealSecretMessage(ChatMessage message) {
    _secretSessions.sealIfInactive(message);
  }

  void _persistSecretConversation(List<ChatMessage> messages) {
    if (messages.isEmpty) return;
    final userId = session?.userId;
    if (userId == null) return;
    _messageCache.upsertMessages(userId, messages).catchError((error) {
      DebugLog.instance.error(
        'secret-chat',
        'Failed to persist sealed message state',
        error,
      );
    });
  }

  void touchSecretSession(String conversationId) {
    _secretSessions.touch(
      conversationId,
      () => deactivateSecretSession(conversationId),
    );
  }

  Future<void> loadSecretChatPreferences() async {
    var seconds = await SecretChatPreferencesStore.instance
        .secretDisappearingSeconds();
    if (seconds == null && await SettingsRuntime.instance.autoDeleteEnabled()) {
      seconds = await SettingsRuntime.instance.outgoingAutoDeleteSeconds();
    }
    secretDisappearingSeconds = seconds;
    _notifyStateChanged();
  }

  Conversation? directConversationWith(String peerUserId) {
    for (final conversation in conversations) {
      if (conversation.isGroup) continue;
      if (conversation.participantUserIds.contains(peerUserId)) {
        return conversation;
      }
    }
    return null;
  }

  Future<void> purgeAllSecretMessages() async {
    final userId = session?.userId;
    for (final entry in messagesByConversation.entries.toList()) {
      final kept = entry.value.where((message) => !message.isSecret).toList();
      if (kept.length == entry.value.length) continue;
      messagesByConversation[entry.key] = kept;
      if (userId != null) {
        await _messageCache.clearConversation(userId, entry.key);
        if (kept.isNotEmpty) {
          await _messageCache.upsertMessages(userId, kept);
        }
      }
    }
    deactivateSecretSessionForAll();
    await refreshConversations();
    _notifyStateChanged();
  }

  Future<void> wipeLocalContentAfterPinFailures() async {
    final userId = session?.userId;
    if (userId != null) await _messageCache.clearUser(userId);
    MediaCache.instance.clear();
    await HiddenVaultSession.instance.wipe();
    messagesByConversation.clear();
    _secretSessions.clearPlaintext();
    deactivateSecretSessionForAll();
    _notifyStateChanged();
  }

  void deactivateSecretSessionForAll() {
    for (final id in _secretSessions.activeConversationIds()) {
      deactivateSecretSession(id);
    }
  }
}
