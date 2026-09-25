part of 'app_controller.dart';

extension AppControllerMessageStorageOperations on AppController {
  Future<void> loadHistory(String conversationId) async {
    if (FavoritesChat.isId(conversationId)) {
      await _syncFavoritesChat();
      _notifyStateChanged();
      return;
    }
    final userId = session?.userId;
    final prior = List<ChatMessage>.from(
      messagesByConversation[conversationId] ?? const [],
    );
    var diskCached = <ChatMessage>[];
    if (userId != null) {
      diskCached = await _messageCache.loadConversation(userId, conversationId);
      if (diskCached.isNotEmpty && prior.isEmpty) {
        for (final message in diskCached) {
          MessagePayload.applyTo(message);
          _sealSecretMessage(message);
        }
        messagesByConversation[conversationId] = diskCached;
        prior.addAll(diskCached);
        await _loadDeliveryInfoForOwnMessages(diskCached, userId);
        await recomputeUnread(conversationId);
        _notifyStateChanged();
      }
    }

    final plaintextIndex = MessageDecryptionSupport.buildPlaintextIndex([
      ...diskCached,
      ...prior,
    ], messagesByConversation[conversationId] ?? const []);
    final runtime = SettingsRuntime.instance;
    if (!await runtime.messageHistorySyncAllowed()) {
      await _finishHistoryLoad(conversationId);
      return;
    }
    final maxAge = await runtime.historySyncMaxAge();
    if (maxAge == Duration.zero) {
      await _finishHistoryLoad(conversationId);
      return;
    }

    final rows = await _api.getMessages(conversationId, limit: 100);
    var remote = rows.map(ChatMessage.fromJson).toList();
    if (maxAge != null) {
      final cutoff = DateTime.now().subtract(maxAge);
      remote = remote
          .where((message) => !message.createdAt.isBefore(cutoff))
          .toList();
    }
    remote.sort((left, right) => left.createdAt.compareTo(right.createdAt));
    final mergedById = <String, ChatMessage>{
      for (final message in prior) message.id: message,
    };
    for (final message in remote) {
      if (_isNonChatEnvelope(message)) {
        await _processHistoryControlMessage(message);
        continue;
      }
      final indexed = plaintextIndex[message.id];
      if (indexed != null) {
        MessageDecryptionSupport.applyPlaintext(message, indexed);
      } else {
        await _decryptInPlace(message, plaintextIndex: plaintextIndex);
      }
      final existing = mergedById[message.id];
      if (_hasUsablePlaintext(existing) && !_hasUsablePlaintext(message)) {
        MessageDecryptionSupport.applyPlaintext(message, existing!);
      }
      mergedById[message.id] = message;
    }

    final merged = mergedById.values.toList()
      ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    messagesByConversation[conversationId] = merged;
    if (userId != null) {
      await _loadDeliveryInfoForOwnMessages(merged, userId);
      await _persistDecryptedMessages(
        userId,
        merged,
        failureContext: 'bulk message persistence failed',
      );
    }
    await _finishHistoryLoad(conversationId);
  }

  bool _hasUsablePlaintext(ChatMessage? message) =>
      message?.plaintext?.isNotEmpty == true && !message!.decryptFailed;

  Future<void> _finishHistoryLoad(String conversationId) async {
    await recomputeUnread(conversationId);
    _notifyStateChanged();
  }

  bool _absorbOutgoingEcho(List<ChatMessage> messages, ChatMessage incoming) {
    final currentUserId = session?.userId;
    if (currentUserId == null || incoming.senderUserId != currentUserId) {
      return false;
    }
    final pendingIndex = messages.indexWhere(
      (message) =>
          message.senderUserId == currentUserId &&
          message.cryptoVersion == 'local-pending' &&
          message.contentType == incoming.contentType &&
          message.createdAt.difference(incoming.createdAt).inSeconds.abs() <
              120,
    );
    if (pendingIndex >= 0) {
      final pending = messages[pendingIndex];
      incoming.plaintext ??= pending.plaintext;
      incoming.replyToMessageId ??= pending.replyToMessageId;
      incoming.replyPreview ??= pending.replyPreview;
      messages[pendingIndex] = incoming;
      return true;
    }
    final duplicateIndex = messages.indexWhere(
      (message) =>
          message.id != incoming.id &&
          message.senderUserId == currentUserId &&
          message.contentType == incoming.contentType &&
          message.ciphertext == incoming.ciphertext,
    );
    if (duplicateIndex < 0) return false;
    messages[duplicateIndex] = incoming;
    return true;
  }

  Future<void> _persistMessage(ChatMessage message) async {
    final userId = session?.userId;
    if (userId == null) return;
    try {
      await _messageCache.upsertMessage(userId, message);
    } catch (error) {
      DebugLog.instance.warn('cache', 'message persistence failed', error);
    }
  }

  Future<void> _persistDecryptedMessages(
    String userId,
    Iterable<ChatMessage> messages, {
    required String failureContext,
  }) async {
    final persistable = messages.where(_hasUsablePlaintext).toList();
    if (persistable.isEmpty) return;
    try {
      await _messageCache.upsertMessages(userId, persistable);
    } catch (error) {
      DebugLog.instance.warn('cache', failureContext, error);
    }
  }

  Future<void> _loadDeliveryInfoForOwnMessages(
    List<ChatMessage> messages,
    String userId,
  ) async {
    for (final message in messages) {
      if (message.senderUserId == userId) {
        await MessageDeliveryStore.instance.loadForMessage(message.id);
      }
    }
  }
}
