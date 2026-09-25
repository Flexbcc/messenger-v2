part of 'app_controller.dart';

extension AppControllerOutboundMessageOperations on AppController {
  Future<void> sendText(
    Conversation conversation,
    String text, {
    String? replyToMessageId,
    String? replyPreview,
  }) async {
    final currentSession = session;
    if (currentSession == null) throw StateError('not authenticated');
    await _ensureDirectConversationNotBlocked(conversation);
    DebugLog.instance.info(
      'send',
      'text to conv=${_shortDebugId(conversation.id)} '
          'peer=${directPeerUserId(conversation)}',
    );
    final clientMessageId = _uuid.v4();
    final secret = _isOutgoingSecret(conversation.id);
    final ttlSeconds = await SettingsRuntime.instance
        .outgoingAutoDeleteSeconds();
    final pending = ChatMessage(
      id: clientMessageId,
      conversationId: conversation.id,
      senderUserId: currentSession.userId,
      senderDeviceId: currentSession.deviceId,
      ciphertext: '',
      contentType: 'text',
      cryptoVersion: 'local-pending',
      createdAt: DateTime.now(),
      plaintext: text,
      replyToMessageId: replyToMessageId,
      replyPreview: replyPreview,
      isSecret: secret,
      ttlSeconds: ttlSeconds,
    );
    messagesByConversation.putIfAbsent(conversation.id, () => []).add(pending);
    await MessageDeliveryStore.instance.setStatus(
      clientMessageId,
      MessageDeliveryStatus.sending,
    );
    _notifyStateChanged();

    try {
      final message = await _outboundMessages.sendText(
        conversation: conversation,
        clientMsgId: clientMessageId,
        text: text,
        secret: secret,
        ttlSeconds: ttlSeconds,
        encrypt: _encryptForConversation,
        replyToMessageId: replyToMessageId,
        replyPreview: replyPreview,
      );
      _replacePendingMessage(conversation.id, clientMessageId, message);
      await MessageDeliveryStore.instance.setStatus(
        message.id,
        MessageDeliveryStatus.sent,
      );
      await _finishOutboundMessage(conversation, message);
    } catch (error) {
      await MessageDeliveryStore.instance.setStatus(
        clientMessageId,
        MessageDeliveryStatus.failed,
        error: error.toString(),
      );
      _notifyStateChanged();
      rethrow;
    }
  }

  Future<void> retryFailedMessage(
    Conversation conversation,
    String messageId,
  ) async {
    final messages = messagesByConversation[conversation.id];
    if (messages == null) return;
    final index = messages.indexWhere((message) => message.id == messageId);
    if (index < 0 ||
        MessageDeliveryStore.instance.infoFor(messageId)?.status !=
            MessageDeliveryStatus.failed) {
      return;
    }
    final text = messages[index].plaintext;
    if (text == null || text.isEmpty) return;
    messages.removeAt(index);
    _notifyStateChanged();
    await sendText(conversation, text);
  }

  Future<void> sendImage(
    Conversation conversation,
    Uint8List bytes,
    String filename,
    String mime,
  ) => sendAttachment(conversation, bytes, filename, mime, 'image');

  Future<void> sendAttachment(
    Conversation conversation,
    Uint8List bytes,
    String filename,
    String mime,
    String contentType,
  ) async {
    final currentSession = session;
    final currentAuthKeyPair = authKeyPair;
    if (currentSession == null || currentAuthKeyPair == null) {
      throw StateError('secure attachment runtime is not initialized');
    }
    await _ensureDirectConversationNotBlocked(conversation);
    final clientMessageId = _uuid.v4();
    final secret = _isOutgoingSecret(conversation.id);
    final ttlSeconds = await SettingsRuntime.instance
        .outgoingAutoDeleteSeconds();
    final pending = ChatMessage(
      id: clientMessageId,
      conversationId: conversation.id,
      senderUserId: currentSession.userId,
      senderDeviceId: currentSession.deviceId,
      ciphertext: '',
      contentType: contentType,
      cryptoVersion: 'local-pending',
      createdAt: DateTime.now(),
      plaintext: '{"pending":true}',
      isSecret: secret,
      ttlSeconds: ttlSeconds,
    );
    messagesByConversation.putIfAbsent(conversation.id, () => []).add(pending);
    _notifyStateChanged();
    try {
      final sent = await _outboundMessages.sendAttachment(
        conversation: conversation,
        clientMsgId: clientMessageId,
        bytes: bytes,
        filename: filename,
        mime: mime,
        contentType: contentType,
        secret: secret,
        ttlSeconds: ttlSeconds,
        userId: currentSession.userId,
        authKeyPair: currentAuthKeyPair,
        encrypt: _encryptForConversation,
      );
      _replacePendingMessage(conversation.id, clientMessageId, sent.message);
      if (!await SettingsRuntime.instance.shouldIsolateHiddenMedia(
        isSecretHidden: isSecretHidden(conversation.id),
      )) {
        _attachmentMedia.cachePlaintext(sent.mediaId, sent.plaintext);
      }
      await _finishOutboundMessage(conversation, sent.message);
    } catch (_) {
      messagesByConversation[conversation.id]?.removeWhere(
        (message) => message.id == clientMessageId,
      );
      _notifyStateChanged();
      rethrow;
    }
  }

  bool _isOutgoingSecret(String conversationId) =>
      isSecretSessionActive(conversationId) &&
      !AppPrivacySession.instance.isInDecoyMode;

  void _replacePendingMessage(
    String conversationId,
    String pendingId,
    ChatMessage message,
  ) {
    final messages = messagesByConversation.putIfAbsent(
      conversationId,
      () => [],
    );
    final index = messages.indexWhere((item) => item.id == pendingId);
    if (index >= 0) {
      messages[index] = message;
    } else {
      messages.add(message);
    }
  }

  Future<void> _finishOutboundMessage(
    Conversation conversation,
    ChatMessage message,
  ) async {
    await _persistMessage(message);
    if (activeConversationId == conversation.id) {
      await markConversationRead(conversation.id);
    } else {
      await recomputeUnread(conversation.id);
    }
    _sortConversations();
    await refreshConversations();
    _notifyStateChanged();
  }

  Future<EncryptedMessagePayload> _encryptForConversation(
    Conversation conversation,
    Uint8List plaintext,
  ) async {
    final currentSession = session;
    if (currentSession == null) throw StateError('not authenticated');
    final peer = directPeerUserId(conversation);
    if (!conversation.isGroup && !isConversationReachable(conversation)) {
      final detail =
          reachabilityErrorFor(conversation) ?? 'Собеседник $peer не найден';
      DebugLog.instance.error('send', detail);
      throw StateError(detail);
    }
    final queueKey = conversation.isGroup
        ? 'group:${conversation.id}'
        : 'direct:$peer';
    return _cryptoSessionQueue.run(
      queueKey,
      () => MessageEncryptionService(api: _api, crypto: _requireCrypto).encrypt(
        conversation: conversation,
        plaintext: plaintext,
        currentUserId: currentSession.userId,
        currentDeviceId: currentSession.deviceId,
        directPeerUserId: peer,
        ensureLegacySession: _ensureSessionWith,
      ),
    );
  }

  Future<Uint8List> _decryptDirectMessage(ChatMessage message) =>
      MessageEncryptionService(api: _api, crypto: _requireCrypto).decryptDirect(
        senderUserId: message.senderUserId,
        senderDeviceId: message.senderDeviceId,
        ciphertext: message.ciphertext,
      );
}
