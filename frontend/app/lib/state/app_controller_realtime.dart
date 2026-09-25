part of 'app_controller.dart';

extension AppControllerRealtimeOperations on AppController {
  void _connectRealtime() {
    final currentSession = session;
    if (currentSession == null) return;
    _realtime.onConnected = () => unawaited(_catchUpMessagesAfterResume());
    _realtime.connect(
      currentSession.accessToken,
      tokenProvider: () async {
        await _relogin();
        final token = session?.accessToken;
        if (token == null) {
          throw StateError('session cleared during reconnect');
        }
        return token;
      },
    );
    _realtimeSub?.cancel();
    _realtimeSub = _realtime.messages.listen((event) {
      _realtimeEventChain = _realtimeEventChain
          .then((_) => _onRealtimeEvent(event))
          .catchError((Object error, StackTrace stackTrace) {
            DebugLog.instance.error('realtime', 'event handling failed', error);
            if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
          });
    });
  }

  Future<void> onAppResumed() async {
    if (session == null) return;
    unawaited(BootstrapStore.refreshBackups());
    if (!await NodeConfigResolver().isPrimaryReachable()) {
      await _maybeFailoverHome();
    }
    if (session == null) return;
    await _relogin();
    _connectRealtime();
    await refreshConversations();
    unawaited(_catchUpMessagesAfterResume());
    await _recordCurrentDeviceSessionMeta();
    await processTimeBasedTasks();
  }

  Future<void> _catchUpMessagesAfterResume() async {
    if (session == null) return;
    final conversationIds = <String>{
      ...messagesByConversation.keys,
      ...conversations.take(20).map((conversation) => conversation.id),
    };
    for (final conversationId in conversationIds) {
      try {
        await _catchUpConversation(conversationId);
      } catch (error) {
        DebugLog.instance.error(
          'sync',
          'catch-up failed for $conversationId: $error',
        );
      }
    }
  }

  Future<void> _catchUpConversation(String conversationId) async {
    if (FavoritesChat.isId(conversationId)) return;
    final userId = session?.userId;
    if (userId == null) return;
    final local = List<ChatMessage>.from(
      messagesByConversation[conversationId] ?? const [],
    );
    DateTime? newest;
    for (final message in local) {
      if (newest == null || message.createdAt.isAfter(newest)) {
        newest = message.createdAt;
      }
    }
    if (newest == null) return;
    final rows = await _api.getMessages(
      conversationId,
      limit: 100,
      after: newest.toUtc().toIso8601String(),
    );
    if (rows.isEmpty) return;

    final plaintextIndex = MessageDecryptionSupport.buildPlaintextIndex(
      local,
      messagesByConversation[conversationId] ?? const [],
    );
    final originalLocalIds = local.map((message) => message.id).toSet();
    final mergedById = <String, ChatMessage>{
      for (final message in local) message.id: message,
    };
    final pendingDeliveryAcks = <String>{};
    var added = false;
    for (final row in rows) {
      final message = ChatMessage.fromJson(row);
      if (mergedById.containsKey(message.id)) {
        if (message.senderUserId != userId) {
          pendingDeliveryAcks.add(message.id);
        }
        continue;
      }
      if (_isNonChatEnvelope(message)) {
        await _processHistoryControlMessage(message);
        if (message.senderUserId != userId) {
          pendingDeliveryAcks.add(message.id);
        }
        continue;
      }
      final indexed = plaintextIndex[message.id];
      if (indexed != null) {
        MessageDecryptionSupport.applyPlaintext(message, indexed);
      } else {
        await _decryptInPlace(message, plaintextIndex: plaintextIndex);
      }
      if (_absorbOutgoingEcho(local, message)) {
        final localIds = local.map((candidate) => candidate.id).toSet();
        mergedById.removeWhere(
          (id, _) => originalLocalIds.contains(id) && !localIds.contains(id),
        );
      }
      mergedById[message.id] = message;
      if (message.senderUserId != userId) {
        pendingDeliveryAcks.add(message.id);
      }
      added = true;
    }
    if (!added) {
      for (final packetId in pendingDeliveryAcks) {
        await _sendDeliveryAck(conversationId, packetId);
      }
      return;
    }

    final merged = mergedById.values.toList()
      ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    messagesByConversation[conversationId] = merged;
    await _loadDeliveryInfoForOwnMessages(merged, userId);
    await _persistDecryptedMessages(
      userId,
      merged,
      failureContext: 'message catch-up persistence failed',
    );
    for (final packetId in pendingDeliveryAcks) {
      await _sendDeliveryAck(conversationId, packetId);
    }
    await recomputeUnread(conversationId);
    _notifyStateChanged();
  }

  Future<void> _onRealtimeEvent(Map<String, dynamic> event) async {
    switch (event['type']) {
      case 'typing':
        _handleRealtimeTyping(event);
      case 'security_signal':
        final fromUserId = event['from_user_id'];
        final code = event['event'];
        if (fromUserId is String && code is int) {
          await ingestSecuritySignal(fromUserId: fromUserId, event: code);
        }
      case 'delivery_ack':
        final packetId = event['packet_id'];
        final deliveryComplete = event['delivery_complete'];
        if (packetId is String &&
            packetId.isNotEmpty &&
            deliveryComplete == true) {
          await MessageDeliveryStore.instance.setStatus(
            packetId,
            MessageDeliveryStatus.delivered,
          );
          _notifyStateChanged();
        }
      case 'home_changed':
        await _handleRealtimeHomeChanged(event);
      case 'session_revoked':
        DebugLog.instance.warn('auth', 'current device session was revoked');
        await logout();
      case 'new_message':
        await _handleRealtimeMessage(event['message']);
    }
  }

  void _handleRealtimeTyping(Map<String, dynamic> event) {
    final conversationId = event['conversation_id'];
    final fromUserId = event['from_user_id'];
    if (conversationId is! String ||
        conversationId.isEmpty ||
        fromUserId is! String ||
        fromUserId == session?.userId ||
        !privacyTypingEnabled) {
      return;
    }
    _typingConversations.add(conversationId);
    _typingTimers.remove(conversationId)?.cancel();
    _typingTimers[conversationId] = Timer(const Duration(seconds: 3), () {
      _typingConversations.remove(conversationId);
      _typingTimers.remove(conversationId);
      _notifyStateChanged();
    });
    _notifyStateChanged();
  }

  Future<void> _handleRealtimeHomeChanged(Map<String, dynamic> event) async {
    final changedUserId = event['user_id'];
    final newHomeUrl = event['home_node_url'];
    final updatedAtRaw = event['home_updated_at'];
    if (changedUserId is! String ||
        changedUserId.isEmpty ||
        changedUserId.length > 256 ||
        newHomeUrl is! String ||
        newHomeUrl.isEmpty) {
      return;
    }
    String validatedHomeUrl;
    try {
      validatedHomeUrl = validatedNetworkOrigin(
        newHomeUrl,
        'home_changed.home_node_url',
      );
    } on FormatException catch (error) {
      DebugLog.instance.warn('routing', 'invalid home_changed event: $error');
      return;
    }
    await PeerHomeCache.instance.set(
      changedUserId,
      homeUrl: validatedHomeUrl,
      updatedAt: updatedAtRaw is String
          ? DateTime.tryParse(updatedAtRaw)
          : null,
    );
    final conversation = findDirectConversationWith(changedUserId);
    if (conversation != null) {
      await validateConversationReachability(conversation);
    }
    _notifyStateChanged();
  }

  Future<void> _handleRealtimeMessage(Object? rawEnvelope) async {
    if (rawEnvelope is! Map<String, dynamic>) {
      throw const FormatException('invalid realtime message envelope');
    }
    final message = ChatMessage.fromRealtimeEnvelope(rawEnvelope);
    if (await _handleRealtimeControlMessage(message)) {
      if (message.senderUserId != session?.userId) {
        unawaited(_sendDeliveryAck(message.conversationId, message.id));
      }
      return;
    }

    final conversationId = message.conversationId;
    if (message.senderUserId != session?.userId) {
      final prior = messagesByConversation[conversationId];
      final weMessaged =
          prior?.any(
            (candidate) => candidate.senderUserId == session?.userId,
          ) ??
          false;
      if (!await _interactionPolicy.canReceiveMessage(
        message.senderUserId,
        isContact: isKnownContact(message.senderUserId),
        hasPriorOutgoing: weMessaged,
      )) {
        DebugLog.instance.info(
          'delivery',
          'incoming message blocked by contact/privacy policy',
        );
        unawaited(_sendDeliveryAck(conversationId, message.id));
        return;
      }
    }

    final messages = messagesByConversation.putIfAbsent(
      conversationId,
      () => [],
    );
    if (messages.any((candidate) => candidate.id == message.id)) {
      if (message.senderUserId != session?.userId) {
        unawaited(_sendDeliveryAck(conversationId, message.id));
      }
      return;
    }
    if (_absorbOutgoingEcho(messages, message)) return;
    await _decryptInPlace(message);
    messages.add(message);
    await _persistMessage(message);
    if (message.senderUserId != session?.userId) {
      unawaited(_sendDeliveryAck(conversationId, message.id));
    }
    if (activeConversationId == conversationId) {
      await markConversationRead(conversationId);
    } else {
      await recomputeUnread(conversationId);
    }
    _maybeNotifyMessage(message, conversationId);
    await refreshConversations();
    _notifyStateChanged();
  }

  Future<bool> _handleRealtimeControlMessage(ChatMessage message) async {
    switch (message.contentType) {
      case 'login_approval_grant':
        return true;
      case 'read_receipt':
        await _handleReadReceipt(message);
        return true;
      case 'sender_key_distribution':
        await _processIncomingDistribution(message);
        return true;
      case surbBundleContentType:
        await _processIncomingSurbBundle(message);
        return true;
    }
    if (CallSignalingService.isCallSignal(message.contentType)) {
      await _handleIncomingCallSignal(message);
      return true;
    }
    return false;
  }

  Future<void> _sendDeliveryAck(String conversationId, String packetId) async {
    const delays = <Duration>[
      Duration.zero,
      Duration(milliseconds: 300),
      Duration(seconds: 1),
      Duration(seconds: 3),
    ];
    Object? lastError;
    for (final delay in delays) {
      if (delay != Duration.zero) await Future<void>.delayed(delay);
      try {
        await _api.ackMessage(conversationId, packetId);
        return;
      } catch (error) {
        lastError = error;
      }
    }
    DebugLog.instance.error(
      'delivery',
      'delivery ack send failed after ${delays.length} attempts: $lastError',
    );
  }
}
