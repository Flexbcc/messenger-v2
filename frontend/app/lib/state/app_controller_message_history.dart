part of 'app_controller.dart';

extension AppControllerMessageHistoryOperations on AppController {
  Future<void> loadChatPreferences(String conversationId) async {
    chatMuted[conversationId] = await _chatPrefs.isMuted(conversationId);
    disappearingSeconds[conversationId] = await _chatPrefs
        .getDisappearingSeconds(conversationId);
    _notifyStateChanged();
  }

  void setActiveConversation(String? conversationId) {
    if (activeConversationId != null &&
        activeConversationId != conversationId) {
      deactivateSecretSession(activeConversationId!);
    }
    activeConversationId = conversationId;
  }

  Future<void> markConversationRead(String conversationId) async {
    final messages = visibleMessagesFor(conversationId);
    final markAt = messages.isNotEmpty
        ? messages.last.createdAt
        : DateTime.now();
    await _chatPrefs.setLastRead(conversationId, markAt);
    unreadCounts[conversationId] = 0;
    await _sendReadReceipt(conversationId, markAt);
    _notifyStateChanged();
  }

  Future<void> _sendReadReceipt(
    String conversationId,
    DateTime readUntil,
  ) async {
    if (session == null ||
        !await SettingsRuntime.instance.readReceiptsEnabled()) {
      return;
    }
    final conversation = _findConversation(conversationId);
    if (conversation == null || conversation.isGroup) return;
    final peer = directPeerUserId(conversation);
    if (peer == null || !isConversationReachable(conversation)) return;
    try {
      final payload = jsonEncode({
        'conversation_id': conversationId,
        'read_until': readUntil.toIso8601String(),
      });
      final encrypted = await _encryptForConversation(
        conversation,
        Uint8List.fromList(utf8.encode(payload)),
      );
      final directConversation = await _findOrCreateDirectConversation(peer);
      await _api.sendMessage(
        conversationId: directConversation.id,
        ciphertext: encrypted.fallback,
        contentType: 'read_receipt',
        deviceEnvelopes: encrypted.deviceEnvelopes,
      );
    } catch (error) {
      DebugLog.instance.error('delivery', 'read_receipt send failed: $error');
    }
  }

  Future<void> _handleReadReceipt(ChatMessage message) async {
    if (!await SettingsRuntime.instance.readReceiptsVisible()) return;
    if (message.plaintext == null) await _decryptInPlace(message);
    final plaintext = message.plaintext;
    if (plaintext == null) return;
    try {
      final decoded = jsonDecode(plaintext);
      if (decoded is! Map<String, dynamic>) return;
      final conversationId = decoded['conversation_id'];
      final untilRaw = decoded['read_until'];
      if (conversationId is! String || untilRaw is! String) return;
      final conversation = _findConversation(conversationId);
      if (conversation == null ||
          conversation.isGroup ||
          directPeerUserId(conversation) != message.senderUserId) {
        return;
      }
      final until = DateTime.parse(untilRaw);
      if (until.isAfter(DateTime.now().add(const Duration(minutes: 5)))) return;
      await MessageDeliveryStore.instance.setPeerReadUntil(
        conversationId,
        until,
      );
      _notifyStateChanged();
    } catch (error) {
      DebugLog.instance.error('delivery', 'read_receipt parse failed: $error');
    }
  }

  Future<void> recomputeUnread(String conversationId) async {
    final lastRead = await _chatPrefs.getLastRead(conversationId);
    final messages = visibleMessagesFor(conversationId);
    unreadCounts[conversationId] = messages.where((message) {
      if (message.senderUserId == session?.userId) return false;
      return lastRead == null || message.createdAt.isAfter(lastRead);
    }).length;
  }

  Future<void> recomputeAllUnread() async {
    for (final conversation in conversations) {
      await recomputeUnread(conversation.id);
    }
  }

  bool _isNonChatEnvelope(ChatMessage message) =>
      _messageVisibility.isControlEnvelope(message);

  Future<void> _processHistoryControlMessage(ChatMessage message) async {
    if (message.contentType == 'read_receipt') {
      await _handleReadReceipt(message);
    } else if (message.contentType == 'sender_key_distribution') {
      await _processIncomingDistribution(message);
    } else if (message.contentType == surbBundleContentType) {
      await _processIncomingSurbBundle(message);
    } else if (CallSignalingService.isCallSignal(message.contentType)) {
      await _handleIncomingCallSignal(message);
    }
  }

  List<ChatMessage> visibleMessagesFor(String conversationId) =>
      _messageVisibility.visible(
        messages: messagesByConversation[conversationId] ?? const [],
        locallyHiddenMessageIds: _messageLocalActions.hiddenIds,
        secretSessionActive: isSecretSessionActive(conversationId),
        disappearingSeconds: disappearingSeconds[conversationId],
        secretDisappearingSeconds: secretDisappearingSeconds,
      );

  DateTime? nextVisibleMessageExpiry(String conversationId) =>
      _messageVisibility.nextExpiry(
        messages: messagesByConversation[conversationId] ?? const [],
        locallyHiddenMessageIds: _messageLocalActions.hiddenIds,
        secretSessionActive: isSecretSessionActive(conversationId),
        disappearingSeconds: disappearingSeconds[conversationId],
        secretDisappearingSeconds: secretDisappearingSeconds,
      );

  List<ChatMessage> searchMessages(String conversationId, String query) =>
      _messageVisibility.search(visibleMessagesFor(conversationId), query);

  List<ChatMessage> imageMessagesFor(String conversationId) =>
      _messageVisibility.images(visibleMessagesFor(conversationId));

  Future<void> clearLocalHistory(String conversationId) async {
    messagesByConversation.remove(conversationId);
    final userId = session?.userId;
    if (userId != null) {
      await _messageCache.clearConversation(userId, conversationId);
    }
    await markConversationRead(conversationId);
    _notifyStateChanged();
  }

  Future<int> restoreLocalMessageHistory(Iterable<ChatMessage> restored) async {
    final userId = session?.userId;
    if (userId == null) return 0;
    final result = await _localHistoryRestore.restore(
      userId: userId,
      knownConversationIds: conversations.map((item) => item.id).toSet(),
      messages: restored,
    );
    messagesByConversation.addAll(result.messagesByConversation);
    if (result.importedCount > 0) _notifyStateChanged();
    return result.importedCount;
  }

  Future<void> reloadLocalCryptographicIdentity() async {
    authKeyPair = await AuthKeyPair.loadOrCreate();
    crypto = await CryptoService.loadOrCreate();
  }

  Future<void> setChatMuted(String conversationId, bool muted) async {
    await _chatPrefs.setMuted(conversationId, muted);
    chatMuted[conversationId] = muted;
    _notifyStateChanged();
  }

  Future<void> setDisappearingSeconds(
    String conversationId,
    int? seconds,
  ) async {
    await _chatPrefs.setDisappearingSeconds(conversationId, seconds);
    disappearingSeconds[conversationId] = seconds;
    _notifyStateChanged();
  }

  String disappearingLabel(String conversationId) {
    final seconds = disappearingSeconds[conversationId];
    if (seconds == null) return 'Выключено';
    return switch (seconds) {
      86400 => '24 часа',
      604800 => '7 дней',
      2592000 => '30 дней',
      _ => '${seconds ~/ 3600} ч',
    };
  }
}
