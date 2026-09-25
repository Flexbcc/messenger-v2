part of 'app_controller.dart';

extension AppControllerCryptoOperations on AppController {
  Future<void> _ensureSessionWith(String otherUserId) async {
    final currentCrypto = crypto;
    if (currentCrypto == null) throw StateError('crypto is not initialized');
    if (await currentCrypto.hasSessionWith(otherUserId)) return;
    DebugLog.instance.info('crypto', 'establish session with $otherUserId');
    final response = await _api.getPreKeyBundle(otherUserId);
    final bundle = response['bundle'];
    if (bundle is! Map<String, dynamic>) {
      throw const FormatException('invalid pre-key bundle response');
    }
    try {
      await currentCrypto.establishSessionFromBundle(otherUserId, bundle);
    } catch (error) {
      if (_isUntrustedIdentityError(error)) {
        await _handleIdentityKeyChange(otherUserId);
      }
      rethrow;
    }
  }

  bool _isUntrustedIdentityError(Object error) {
    final text = error.toString();
    return text.contains('UntrustedIdentityException') ||
        text.contains('Untrusted identity');
  }

  Future<void> _handleIdentityKeyChange(String userId) async {
    final runtime = SettingsRuntime.instance;
    if (await runtime.keyChangeWarning()) {
      await setContactTrustLevel(userId, TrustLevel.unknown, logEvent: false);
      await SecurityLogService.instance.append(
        SecurityEvent(
          title: 'Ключ контакта изменился',
          subtitle: labelFor(userId),
          at: DateTime.now(),
          icon: 'shield',
        ),
      );
      InAppNotificationService.instance.notify(
        InAppNotificationEvent(
          title: 'Ключ изменился',
          body: 'Проверьте безопасность: ${labelFor(userId)}',
          playSound: true,
          vibrate: true,
        ),
      );
    }
    if (await runtime.blockOnKeyChange()) {
      await runtime.blockUser(userId);
      await SecurityLogService.instance.append(
        SecurityEvent(
          title: 'Контакт заблокирован после смены ключа',
          subtitle: labelFor(userId),
          at: DateTime.now(),
          icon: 'block',
        ),
      );
    }
  }

  Future<void> _decryptInPlace(
    ChatMessage message, {
    Map<String, ChatMessage>? plaintextIndex,
  }) async {
    final indexed = plaintextIndex?[message.id];
    if (indexed != null) {
      MessageDecryptionSupport.applyPlaintext(message, indexed);
      if (message.plaintext != null) return;
    }
    final cached = messagesByConversation[message.conversationId]
        ?.where((candidate) => candidate.id == message.id)
        .firstOrNull;
    if (_hasUsablePlaintext(cached)) {
      MessageDecryptionSupport.applyPlaintext(message, cached!);
      return;
    }
    if (message.senderUserId == session?.userId &&
        message.senderDeviceId == session?.deviceId) {
      return;
    }

    final conversation = _findConversation(message.conversationId);
    final queueKey = MessageDecryptionSupport.queueKey(
      message,
      conversation: conversation,
    );
    await _cryptoSessionQueue.run(queueKey, () async {
      if (message.plaintext != null) return;
      try {
        final currentCrypto = crypto;
        if (currentCrypto == null) {
          throw StateError('crypto is not initialized');
        }
        final isGroupCiphertext =
            conversation?.isGroup == true &&
            message.ciphertext.contains('"group":true');
        final plaintextBytes = isGroupCiphertext
            ? await currentCrypto.decryptGroup(
                message.conversationId,
                message.senderUserId,
                message.ciphertext,
              )
            : await _decryptDirectMessage(message);
        message.plaintext = utf8.decode(plaintextBytes);
        message.decryptFailed = false;
        MessagePayload.applyTo(message);
        _sealSecretMessage(message);
      } catch (error) {
        if (_isUntrustedIdentityError(error)) {
          await _handleIdentityKeyChange(message.senderUserId);
        }
        if (MessageDecryptionSupport.isDuplicateDecryptError(error)) {
          final fromIndex = plaintextIndex?[message.id];
          if (fromIndex != null) {
            MessageDecryptionSupport.applyPlaintext(message, fromIndex);
            if (message.plaintext != null) return;
          }
          final inMemory = messagesByConversation[message.conversationId]
              ?.where((candidate) => candidate.id == message.id)
              .firstOrNull;
          if (_hasUsablePlaintext(inMemory)) {
            MessageDecryptionSupport.applyPlaintext(message, inMemory!);
            return;
          }
        }
        message.decryptFailed = true;
        final shortId = message.id.length <= 8
            ? message.id
            : message.id.substring(0, 8);
        DebugLog.instance.error(
          'crypto',
          'decrypt failed msg=$shortId… sender=${message.senderUserId}: $error',
        );
      }
    });
  }

  Future<Conversation> _findOrCreateDirectConversation(
    String otherUserId,
  ) async {
    for (final conversation in conversations) {
      if (!conversation.isGroup &&
          conversation.participantUserIds.contains(otherUserId) &&
          conversation.participantUserIds.length == 2) {
        return conversation;
      }
    }
    final response = await _api.createConversation(
      type: 'direct',
      participantUserIds: [otherUserId],
    );
    final conversation = Conversation.fromJson(response);
    conversations.add(conversation);
    return conversation;
  }
}
