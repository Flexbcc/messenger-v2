part of 'app_controller.dart';

extension AppControllerE2eeControlOperations on AppController {
  Future<void> _processIncomingDistribution(ChatMessage message) async {
    if (message.senderUserId == session?.userId) return;
    await _cryptoSessionQueue.run('direct:${message.senderUserId}', () async {
      final currentCrypto = crypto;
      if (currentCrypto == null) return;
      try {
        final plaintextBytes = await currentCrypto.decrypt(
          message.senderUserId,
          message.ciphertext,
        );
        final decoded = jsonDecode(utf8.decode(plaintextBytes));
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('sender-key payload must be an object');
        }
        final groupId = decoded['group_id'];
        final distribution = decoded['distribution'];
        if (groupId is! String ||
            groupId.isEmpty ||
            distribution is! String ||
            distribution.isEmpty) {
          throw const FormatException('invalid sender-key distribution');
        }
        await currentCrypto.processGroupSenderKeyDistribution(
          groupId,
          message.senderUserId,
          distribution,
        );
      } catch (error) {
        DebugLog.instance.warn(
          'crypto',
          'sender-key distribution rejected: $error',
        );
      }
    });
  }

  Future<void> _processIncomingSurbBundle(ChatMessage message) async {
    final localUserId = session?.userId;
    if (localUserId == null || message.senderUserId == localUserId) return;
    await _cryptoSessionQueue.run('direct:${message.senderUserId}', () async {
      try {
        final plaintext = await _decryptDirectMessage(message);
        final bundle = SurbBundle.decode(utf8.decode(plaintext));
        await SurbDeliveryStore.instance.addBundle(
          localUserId,
          message.senderUserId,
          bundle,
        );
      } catch (error) {
        DebugLog.instance.warn('transport', 'SURB bundle rejected: $error');
      }
    });
  }

  Future<void> sendSurbBundle(
    String peerUserId,
    List<SurbReplyBlock> replyBlocks,
  ) async {
    if (session == null || replyBlocks.isEmpty) return;
    final conversation = await _findOrCreateDirectConversation(peerUserId);
    final bundle = SurbBundle(bundleId: _uuid.v4(), replyBlocks: replyBlocks);
    final encrypted = await _encryptForConversation(
      conversation,
      Uint8List.fromList(utf8.encode(bundle.encode())),
    );
    await _api.sendMessage(
      conversationId: conversation.id,
      ciphertext: encrypted.fallback,
      contentType: surbBundleContentType,
      clientMsgId: bundle.bundleId,
      deviceEnvelopes: encrypted.deviceEnvelopes,
    );
  }

  Future<SurbReplyBlock?> consumeSurbFor(String peerUserId) async {
    final localUserId = session?.userId;
    if (localUserId == null) return null;
    return SurbDeliveryStore.instance.consume(localUserId, peerUserId);
  }
}
