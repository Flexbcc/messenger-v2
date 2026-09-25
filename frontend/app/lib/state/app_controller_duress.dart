part of 'app_controller.dart';

extension AppControllerDuressOperations on AppController {
  Future<void> sendDuressSignalToTrusted({
    required int code,
    DuressTrigger? trigger,
    List<String>? channelsOverride,
  }) async {
    if (!await SettingsRuntime.instance.distressSignalEnabled()) {
      DebugLog.instance.info('duress', 'distress_signal disabled — skip send');
      return;
    }
    final routing = await _duressRouting(
      channelsOverride: channelsOverride,
      defaultChannels: const ['chat'],
      preferCatalogContacts: true,
    );
    if (routing.trustedUserIds.isEmpty) return;
    if (!_duressChannelEnabled(routing.channels, 'chat')) return;
    var sent = false;
    for (final peerId in routing.trustedUserIds) {
      final conversation = directConversationWith(peerId);
      if (conversation == null) continue;
      sent = await _sendDuressMessage(conversation, code: code) || sent;
    }
    if (sent) {
      await DuressAuditService.instance.recordOutbound(
        code: code,
        channel: 'chat',
        trigger: trigger,
      );
    }
  }

  Future<void> relaySecuritySignal({
    required int event,
    DuressTrigger? trigger,
    List<String>? channelsOverride,
  }) async {
    final routing = await _duressRouting(
      channelsOverride: channelsOverride,
      defaultChannels: const ['relay'],
    );
    if (routing.trustedUserIds.isEmpty) return;
    if (!_duressChannelEnabled(routing.channels, 'relay')) return;
    if (!await DuressRateLimiter.instance.allowRelay()) {
      if (_duressChannelEnabled(routing.channels, 'chat')) {
        await sendDuressSignalToTrusted(code: event, trigger: trigger);
      }
      return;
    }
    final delivered = await SecuritySignalClient(
      _api,
    ).relay(event: event, targets: routing.trustedUserIds);
    if (delivered) {
      await DuressAuditService.instance.recordOutbound(
        code: event,
        channel: 'relay',
        trigger: trigger,
      );
    } else if (_duressChannelEnabled(routing.channels, 'chat')) {
      await sendDuressSignalToTrusted(code: event, trigger: trigger);
    }
  }

  Future<String> testDuressDelivery({int code = 90}) async {
    final routing = await _duressRouting(
      defaultChannels: const ['chat', 'relay'],
    );
    if (routing.trustedUserIds.isEmpty) {
      return 'Добавьте доверенные контакты';
    }
    final parts = <String>[];
    if (_duressChannelEnabled(routing.channels, 'chat')) {
      await sendDuressSignalToTrusted(code: code);
      parts.add('чат');
    }
    if (_duressChannelEnabled(routing.channels, 'relay')) {
      await relaySecuritySignal(event: code);
      final last = await DuressAuditService.instance.lastOutbound();
      if (last?.code == code && last?.channel == 'relay') {
        parts.add('relay');
      } else if (last?.code == code &&
          last?.channel == 'chat' &&
          !parts.contains('чат')) {
        parts.add('чат (fallback)');
      } else {
        parts.add('relay не доставлен');
      }
    }
    if (parts.isEmpty) return 'Каналы доставки не выбраны';
    return 'Код $code: ${parts.join(', ')}';
  }

  Future<({List<String> trustedUserIds, List<String> channels})>
  _duressRouting({
    required List<String> defaultChannels,
    List<String>? channelsOverride,
    bool preferCatalogContacts = false,
  }) async {
    if (preferCatalogContacts) {
      final catalog = await SettingsRuntime.instance.distressContacts();
      if (catalog.isNotEmpty) {
        return (
          trustedUserIds: catalog.toSet().toList(),
          channels: channelsOverride ?? defaultChannels,
        );
      }
    }
    if (DuressPolicySession.instance.isUnlocked) {
      final data = DuressPolicySession.instance.data;
      return (
        trustedUserIds: (data?.trustedUserIds ?? const <String>[])
            .toSet()
            .toList(),
        channels: channelsOverride ?? data?.trustedChannels ?? defaultChannels,
      );
    }
    final mirror = await DuressRuntimeStore.instance.loadMirror();
    return (
      trustedUserIds: mirror.trustedUserIds.toSet().toList(),
      channels: channelsOverride ?? mirror.trustedChannels,
    );
  }

  bool _duressChannelEnabled(List<String> channels, String channel) =>
      channels.contains('both') || channels.contains(channel);

  Future<void> ingestSecuritySignal({
    required String fromUserId,
    required int event,
  }) async {
    if (session == null) return;
    final conversation = directConversationWith(fromUserId);
    if (conversation == null) return;
    final wireBody = MessagePayload.encodeDuress(code: event);
    final message = ChatMessage(
      id: 'duress-ws-${DateTime.now().millisecondsSinceEpoch}',
      conversationId: conversation.id,
      senderUserId: fromUserId,
      senderDeviceId: null,
      ciphertext: '',
      contentType: 'text',
      cryptoVersion: 'local-duress',
      createdAt: DateTime.now(),
      plaintext: wireBody,
    );
    MessagePayload.applyTo(message);
    messagesByConversation.putIfAbsent(conversation.id, () => []).add(message);
    await _persistMessage(message);
    if (activeConversationId == conversation.id) {
      await markConversationRead(conversation.id);
    }
    _notifyStateChanged();
  }

  Future<bool> _sendDuressMessage(
    Conversation conversation, {
    required int code,
  }) async {
    if (session == null) return false;
    final wireBody = MessagePayload.encodeDuress(code: code);
    try {
      final encrypted = await _encryptForConversation(
        conversation,
        Uint8List.fromList(utf8.encode(wireBody)),
      );
      final response = await _api.sendMessage(
        conversationId: conversation.id,
        ciphertext: encrypted.fallback,
        contentType: 'text',
        deviceEnvelopes: encrypted.deviceEnvelopes,
      );
      final message = ChatMessage.fromJson(response)..plaintext = wireBody;
      MessagePayload.applyTo(message);
      final messages = messagesByConversation.putIfAbsent(
        conversation.id,
        () => [],
      );
      if (!messages.any((candidate) => candidate.id == message.id)) {
        messages.add(message);
        await _persistMessage(message);
      }
      _notifyStateChanged();
      return true;
    } catch (error) {
      DebugLog.instance.error('duress', 'system alert failed: $error');
      return false;
    }
  }
}
