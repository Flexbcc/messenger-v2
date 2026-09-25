part of 'app_controller.dart';

extension AppControllerPrivacyOperations on AppController {
  Future<void> _loadHiddenChatsPolicies() async {
    final runtime = SettingsRuntime.instance;
    hiddenChatsEnabled = await runtime.hiddenEnabled();
    hiddenChatsOpenMethod = await runtime.hiddenOpenMethod();
    hiddenChatsExcludeFromSearch = await runtime.hiddenHideFromSearch();
    hiddenChatsSilenceNotifications = await runtime.hiddenHideNotifications();
    hiddenChatsHideMedia = await runtime.hiddenHideMedia();
    if (hiddenChatsHideMedia && _secretHiddenConversationIds.isNotEmpty) {
      MediaCache.instance.clear();
    }
    hiddenChatsSort = await HiddenChatsStore.instance.sortOrder();
    await _loadPrivacyPolicies();
  }

  Future<void> _loadPrivacyPolicies() async {
    final runtime = SettingsRuntime.instance;
    privacyOnlineStatusEnabled = await runtime.onlineStatusEnabled();
    privacyInvisibleMode = await runtime.invisibleMode();
    privacyLastSeenPolicy = await runtime.lastSeenPolicy();
    privacyLastSeenList = (await CatalogListStore().load(
      'privacy.last_seen_list',
    )).toSet();
    privacyTypingEnabled = await runtime.typingEnabled();
    privacyReadReceiptsVisible = await runtime.readReceiptsVisible();
    if (session == null) return;
    try {
      await _api.updatePresencePolicy(
        onlineStatus: privacyOnlineStatusEnabled,
        lastSeen: privacyLastSeenPolicy,
        selectedUserIds: privacyLastSeenList.toList(),
        invisible: privacyInvisibleMode,
      );
    } catch (error) {
      DebugLog.instance.warn('presence', 'policy update failed: $error');
    }
  }

  Future<void> refreshHiddenChatsPolicies() async {
    await _loadHiddenChatsPolicies();
    _notifyStateChanged();
  }

  Future<void> refreshPrivacyRuntime() async {
    await _loadPrivacyPolicies();
    _notifyStateChanged();
  }

  bool isKnownContact(String userId) =>
      knownDisplayNames.containsKey(userId) ||
      (contactTrustLevels[userId] != null &&
          contactTrustLevels[userId] != TrustLevel.unknown);

  bool _visibilityAllowsSync(
    String policy,
    Set<String> list,
    String viewerUserId,
  ) => switch (policy) {
    'nobody' => false,
    'contacts' => isKnownContact(viewerUserId),
    'selected' => list.contains(viewerUserId),
    'everyone' => true,
    _ => isKnownContact(viewerUserId),
  };

  bool canShowOnlineStatusFor(String peerUserId) {
    if (privacyInvisibleMode || !privacyOnlineStatusEnabled) return false;
    return _visibilityAllowsSync(
      privacyLastSeenPolicy,
      privacyLastSeenList,
      peerUserId,
    );
  }

  bool canShowLastSeenFor(String peerUserId) {
    if (privacyInvisibleMode) return false;
    return _visibilityAllowsSync(
      privacyLastSeenPolicy,
      privacyLastSeenList,
      peerUserId,
    );
  }

  Future<void> notifyTyping(String conversationId) async {
    if (!privacyTypingEnabled) return;
    if (!await SettingsRuntime.instance.typingEnabled()) return;
    _realtime.send({'type': 'typing', 'conversation_id': conversationId});
  }

  bool isPeerTyping(String conversationId) =>
      privacyTypingEnabled && _typingConversations.contains(conversationId);

  Future<void> reloadSecretHiddenFromStore() async {
    _secretHiddenConversationIds
      ..clear()
      ..addAll(await HiddenChatsStore.instance.loadSecretHiddenIds());
    await _persistHiddenChatIds();
    await _loadHiddenChatsPolicies();
    _notifyStateChanged();
  }

  Future<void> hideConversationAsSecret(String conversationId) async {
    if (!await SettingsRuntime.instance.hiddenEnabled()) {
      throw StateError('Скрытые чаты отключены');
    }
    _secretHiddenConversationIds.add(conversationId);
    await HiddenChatsStore.instance.addSecretHidden(conversationId);
    await _persistHiddenChatIds();
    if (hiddenChatsHideMedia) MediaCache.instance.clear();
    if (activeConversationId == conversationId) activeConversationId = null;
    _notifyStateChanged();
  }

  Future<void> unhideConversation(String conversationId) async {
    _secretHiddenConversationIds.remove(conversationId);
    await HiddenChatsStore.instance.removeSecretHidden(conversationId);
    await _persistHiddenChatIds();
    _notifyStateChanged();
  }

  Future<void> _persistHiddenChatIds() => CatalogListStore().save(
    'hidden.chat_list',
    _secretHiddenConversationIds.toList(),
  );

  Future<void> hideConversationLocally(String conversationId) async {
    _hiddenConversationIds.add(conversationId);
    await _localSettings.setStringList(
      'hidden_conversations',
      _hiddenConversationIds.toList(),
    );
    messagesByConversation.remove(conversationId);
    if (activeConversationId == conversationId) activeConversationId = null;
    _notifyStateChanged();
  }
}
