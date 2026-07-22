import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../calls/active_call.dart';
import '../config.dart';
import '../calls/call_media_controller.dart';
import '../calls/call_signal.dart';
import '../calls/call_signaling_service.dart';
import '../crypto/auth_keypair.dart';
import '../crypto/crypto_service.dart';
import '../crypto/media_crypto.dart';
import '../models/call_history_entry.dart';
import '../models/connection_probe_result.dart';
import '../models/contact_trust.dart';
import '../models/conversation.dart';
import '../models/device_info.dart';
import '../models/device_trust.dart';
import '../models/login_approval_request.dart';
import '../models/message_delivery_info.dart';
import '../models/message.dart';
import '../services/api_client.dart';
import '../services/call_history_store.dart';
import '../services/chat_preferences_store.dart';
import '../services/contact_store.dart';
import '../services/connection_status_service.dart';
import '../services/contact_trust_store.dart';
import '../services/debug_log.dart';
import '../services/device_trust_store.dart';
import '../models/device_session_meta.dart';
import '../services/device_session_meta_store.dart';
import '../models/emergency_lock_level.dart';
import '../services/emergency_lock_service.dart';
import '../services/hidden_chats_store.dart';
import '../services/hidden_vault_session.dart';
import '../services/login_approval_service.dart';
import '../services/local_settings_store.dart';
import '../services/media_cache.dart';
import '../services/gallery_save_service.dart';
import '../services/media_quality.dart';
import '../services/ppc/personal_pc_media_store.dart';
import '../services/message_cache_store.dart';
import '../services/message_delivery_store.dart';
import '../services/outbox_queue.dart';
import '../services/message_local_actions_store.dart';
import '../services/in_app_notification_service.dart';
import '../services/os_notification_service.dart';
import '../services/network_usage_store.dart';
import '../services/secret_chat_preferences_store.dart';
import '../security/secret_chat_security.dart';
import '../security/pin_security.dart';
import '../services/app_privacy_session.dart';
import '../services/account_settings_scope.dart';
import '../models/duress_policy.dart';
import '../services/duress_audit_service.dart';
import '../services/duress_policy_session.dart';
import '../services/duress_policy_engine.dart';
import '../services/duress_rate_limiter.dart';
import '../services/duress_runtime_store.dart';
import '../services/security_signal_client.dart';
import '../services/security_log_service.dart';
import '../services/security_meta_store.dart';
import '../state/notification_settings.dart';
import '../models/favorite_item.dart';
import '../models/message_reminder.dart';
import '../models/scheduled_message.dart';
import '../services/favorites_store.dart';
import '../services/favorites_preferences_store.dart';
import '../services/message_reminder_store.dart';
import '../services/scheduled_message_store.dart';
import '../utils/format.dart';
import '../utils/message_format.dart';
import '../utils/message_payload.dart';
import '../utils/favorites_chat.dart';
import '../utils/user_id.dart';
import '../utils/crypto_serial_queue.dart';
import '../services/realtime_service.dart';
import '../services/session_store.dart';
import '../services/settings_runtime.dart';
import '../services/catalog_list_store.dart';

final appControllerProvider = ChangeNotifierProvider<AppController>((ref) => AppController());

/// Single pragmatic app-state holder for the MVP (see ADR-0004 — simplicity
/// over textbook layering while the product surface is still small).
class AppController extends ChangeNotifier {
  final _sessionStore = SessionStore();
  final _api = ApiClient();
  final _realtime = RealtimeService();
  StreamSubscription<Map<String, dynamic>>? _realtimeSub;
  static const _callOfferMaxAge = Duration(seconds: 90);
  final _chatPrefs = ChatPreferencesStore();
  final _callHistoryStore = CallHistoryStore();
  final _contactStore = ContactStore();
  final _contactTrustStore = ContactTrustStore();
  final _deviceTrustStore = DeviceTrustStore();
  final _connectionStatus = const ConnectionStatusService();
  final _localSettings = LocalSettingsStore();
  final _messageCache = MessageCacheStore.instance;
  final _uuid = const Uuid();
  final _cryptoDecryptQueue = CryptoSerialQueue();
  Future<void> _realtimeEventChain = Future<void>.value();
  Timer? _timeTasksTimer;

  int scheduledMessageCount = 0;
  bool favoritesChatEnabled = true;

  /// Cached reachability per direct conversation (peer has prekey bundle on server).
  final Map<String, bool> conversationReachable = {};
  final Map<String, String?> conversationReachabilityError = {};

  /// Injected from root UI after boot — see main.dart.
  NotificationSettings? notificationSettings;

  Session? session;
  CryptoService? crypto;
  AuthKeyPair? authKeyPair;

  // Populated on demand by loadMyProfile() (see account_screen.dart) — not
  // fetched at boot/login to avoid slowing those down; phone/login/email
  // aren't needed until the user opens "Аккаунт".
  String? phone;
  String? login;
  String? email;

  List<DeviceInfo> devices = [];

  bool booting = true;
  bool get isLoggedIn => session != null;

  List<Conversation> conversations = [];
  final Map<String, List<ChatMessage>> messagesByConversation = {};
  final Map<String, String> knownDisplayNames = {}; // local cache, see shared/README.md

  /// Conversation currently open in [ChatScreen] — used for read/unread tracking.
  String? activeConversationId;

  /// Cached unread counts per conversation (recomputed after reads/messages).
  final Map<String, int> unreadCounts = {};

  /// Cached per-chat prefs for synchronous UI reads.
  final Map<String, bool> chatMuted = {};
  final Map<String, int?> disappearingSeconds = {};

  /// userId → Set of conversationIds where that user is currently typing.
  /// Populated by incoming WS `typing` events and auto-cleared after timeout.
  final Map<String, Set<String>> _typingByUser = {};
  final Map<String, Timer> _typingTimers = {};

  /// Returns true if any peer (not us) is typing in [conversationId].
  bool anyoneTypingIn(String conversationId) {
    final myId = session?.userId;
    return _typingByUser.entries.any(
      (e) => e.key != myId && e.value.contains(conversationId),
    );
  }

  void _setTyping(String userId, String conversationId) {
    _typingByUser.putIfAbsent(userId, () => {}).add(conversationId);
    // Auto-clear after 6 s (server should re-send every ~4 s while typing).
    final key = '$userId:$conversationId';
    _typingTimers[key]?.cancel();
    _typingTimers[key] = Timer(const Duration(seconds: 6), () {
      _typingByUser[userId]?.remove(conversationId);
      _typingTimers.remove(key);
      notifyListeners();
    });
    notifyListeners();
  }

  /// Active secret-chat sessions per conversation (device-local).
  final Set<String> _secretSessionActive = {};
  final Map<String, Timer> _secretSessionTimers = {};
  /// Plaintext for sealed secret messages (hidden until secret session in chat).
  final Map<String, String> _secretPlaintextVault = {};
  int? secretDisappearingSeconds;

  /// Local call log (newest first).
  List<CallHistoryEntry> callHistory = [];

  /// Locally hidden chats (broken peers, user dismissed).
  final Set<String> _hiddenConversationIds = {};

  /// Secret-hidden chats — absent from main list, shown only in Hidden Chats.
  final Set<String> _secretHiddenConversationIds = {};

  /// Groups created on this device — exempt from privacy.group_invites filter.
  final Set<String> _locallyCreatedGroupIds = {};

  /// Cached decoy allow-list (conversation ids) while in fake profile mode.
  List<String> _fakeProfileChatIds = const [];

  bool hiddenChatsExcludeFromSearch = true;
  bool hiddenChatsSilenceNotifications = true;
  bool hiddenChatsHideMedia = true;
  bool hiddenChatsEnabled = false;
  String hiddenChatsOpenMethod = 'pin';
  HiddenChatSort hiddenChatsSort = HiddenChatSort.recent;

  /// Cached privacy.* flags for sync UI (refreshed via [refreshPrivacyRuntime]).
  bool privacyOnlineStatusEnabled = true;
  bool privacyInvisibleMode = false;
  String privacyLastSeenPolicy = 'contacts';
  Set<String> privacyLastSeenList = {};
  bool privacyTypingEnabled = true;
  bool privacyReadReceiptsVisible = true;

  /// Locally saved contact name overrides — take priority over server names.
  Map<String, String> _contactAliases = {};

  /// Per-contact trust levels — default [TrustLevel.unknown] when absent.
  Map<String, TrustLevel> contactTrustLevels = {};

  /// Per-device trust & Private Mode access — defaults applied in [deviceTrustFor].
  Map<String, DeviceTrustProfile> deviceTrustProfiles = {};

  /// Locally reported client metadata per device session.
  Map<String, DeviceSessionMeta> deviceSessionMeta = {};

  /// When conversations were last fetched from Home Node.
  DateTime? lastConversationSyncAt;

  bool get websocketConnected => _realtime.isConnected;

  /// Groups whose sender key has already been distributed to all members
  /// this session — see 0301_GROUP_MESSAGING.md. Reset on restart (in
  /// memory only), matching CryptoService's sender-key store lifetime.
  final Set<String> _groupKeysDistributed = {};

  /// Locally hidden / pinned messages (device-only).
  final Set<String> _locallyHiddenMessageIds = {};
  final Set<String> _pinnedMessageIds = {};

  /// The one call (incoming or outgoing) currently ringing/in progress —
  /// see spec/0303_CALLS.md, ADR-0008. Null when there is none.
  ActiveCall? currentCall;

  /// New device login blocked until approved on a trusted device.
  bool loginApprovalPending = false;

  /// Incoming login requests detected on this trusted device.
  List<LoginApprovalRequest> pendingLoginApprovals = [];

  /// When true, full-screen call UI is hidden and a compact bar is shown instead.
  bool callUiMinimized = false;

  /// Brief post-hangup overlay (“Звонок завершён”) after [endCall]/reject/cancel.
  String? callEndedPeerLabel;

  void setCallUiMinimized(bool minimized) {
    callUiMinimized = minimized;
    notifyListeners();
  }

  void clearCallEndedOverlay() {
    if (callEndedPeerLabel == null) return;
    callEndedPeerLabel = null;
    notifyListeners();
  }

  void _showCallEndedOverlay(String peerLabel) {
    callEndedPeerLabel = peerLabel;
    notifyListeners();
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (callEndedPeerLabel == peerLabel) {
        callEndedPeerLabel = null;
        notifyListeners();
      }
    });
  }

  CallSignalingService get _callSignaling => CallSignalingService(crypto!);

  Conversation? _findConversation(String id) {
    for (final c in conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> boot() async {
    try {
      authKeyPair = await AuthKeyPair.loadOrCreate();
      crypto = await CryptoService.loadOrCreate();
      await OutboxQueue.instance.load();

      final existing = await _sessionStore.load();
      knownDisplayNames.clear();
      _contactAliases = await loadAllContactAliases();
      contactTrustLevels = await loadAllContactTrust();
      deviceTrustProfiles = await loadAllDeviceTrust();
      knownDisplayNames.addAll(_contactAliases);
      callHistory = await _callHistoryStore.loadAll();
      if (existing != null) {
        // Bind settings/PIN namespace before reading any account-local prefs.
        await AccountSettingsScope.activate(existing.userId);
      }
      _hiddenConversationIds
        ..clear()
        ..addAll(await _localSettings.getStringList('hidden_conversations'));
      _secretHiddenConversationIds
        ..clear()
        ..addAll(await HiddenChatsStore.instance.loadSecretHiddenIds());
          await _loadHiddenChatsPolicies();
          await _loadFavoritesPreferences();
          await loadSecretChatPreferences();
          await _syncFavoritesChat();
          if (existing != null) {
            try {
              session = existing;
              _api.accessToken = existing.accessToken;
              await _loadMessageLocalActions();
          await _relogin();
          await _api.getMyProfile();
          await refreshConversations();
          _connectRealtime();
          loginApprovalPending = await LoginApprovalService.instance.isDeviceAwaitingApproval(session!.deviceId);
          if (!loginApprovalPending) {
            await refreshDevices();
          }
          _startTimeTasksTimer();
          unawaited(processTimeBasedTasks());
          unawaited(_replenishPrekeysIfNeeded());
        } on ApiException catch (e) {
          DebugLog.instance.warn('auth', 'stale session ${e.statusCode}, clearing local login');
          await _sessionStore.clear();
          session = null;
          _api.accessToken = null;
          await AccountSettingsScope.deactivate();
        } catch (e) {
          DebugLog.instance.error('auth', 'session restore failed, clearing local login: $e');
          await _sessionStore.clear();
          session = null;
          _api.accessToken = null;
          await AccountSettingsScope.deactivate();
        }
      }
    } finally {
      booting = false;
      notifyListeners();
    }
  }

  Future<void> _loadMessageLocalActions() async {
    final userId = session?.userId;
    if (userId == null) return;
    _locallyHiddenMessageIds
      ..clear()
      ..addAll(await MessageLocalActionsStore.instance.loadHidden(userId));
    _pinnedMessageIds
      ..clear()
      ..addAll(await MessageLocalActionsStore.instance.loadPinned(userId));
  }

  bool isMessagePinned(String messageId) => _pinnedMessageIds.contains(messageId);

  Future<void> hideMessageLocally(String messageId) async {
    final userId = session?.userId;
    if (userId == null) return;
    _locallyHiddenMessageIds.add(messageId);
    await MessageLocalActionsStore.instance.hideMessage(userId, messageId);
    notifyListeners();
  }

  Future<void> toggleMessagePinned(String messageId) async {
    final userId = session?.userId;
    if (userId == null) return;
    final pinned = _pinnedMessageIds.contains(messageId);
    if (pinned) {
      _pinnedMessageIds.remove(messageId);
    } else {
      _pinnedMessageIds.add(messageId);
    }
    await MessageLocalActionsStore.instance.setPinned(userId, messageId, !pinned);
    notifyListeners();
  }

  Future<void> forwardMessage(ChatMessage message, Conversation target) async {
    final body = messageDisplayBody(message);
    final text = message.contentType == 'image' ? '↪ 📷 $body' : '↪ $body';
    await sendText(target, text);
  }

  Future<void> _relogin() async {
    if (session == null || authKeyPair == null) return;
    try {
      final challenge = await _api.challenge(session!.deviceId);
      final nonceBytes = base64Decode(challenge['nonce'] as String);
      final signature = await authKeyPair!.signBase64(nonceBytes);
      final verified = await _api.verify(
        deviceId: session!.deviceId,
        nonce: challenge['nonce'] as String,
        signature: signature,
      );
      session!.accessToken = verified['access_token'] as String;
      _api.accessToken = session!.accessToken;
      await _sessionStore.saveToken(session!.accessToken);
    } catch (_) {
      // Token from storage might still be valid; if not, requests will 401
      // and the UI can prompt a fresh register. Acceptable for MVP.
    }
  }

  Future<void> register({
    required String displayName,
    required String phone,
    String? login,
    String? email,
    required String password,
  }) async {
    if (await EmergencyLockService.instance.isRecoveryLockActive()) {
      throw StateError('Аккаунт заблокирован. Требуется ключ восстановления.');
    }
    authKeyPair = await AuthKeyPair.loadOrCreate();
    crypto = await CryptoService.loadOrCreate();
    final bundle = await crypto!.generatePublishableBundle();

    final result = await _api.register(
      displayName: displayName,
      phone: phone,
      login: login,
      email: email,
      password: password,
      deviceName: defaultTargetPlatform.name,
      deviceType: kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase(),
      authPublicKey: authKeyPair!.publicKeyBase64,
      identityKeyBundle: bundle,
    );
    await _finishLogin(result, displayName);
  }

  /// ADR-0007 temporary bridge login by phone/login/email + password.
  /// May attach as a new Device under an existing account.
  Future<void> loginWithPassword(String identifier, String password) async {
    if (await EmergencyLockService.instance.isRecoveryLockActive()) {
      throw StateError('Аккаунт заблокирован. Требуется ключ восстановления.');
    }
    if (await EmergencyLockService.instance.areNewLoginsBlocked()) {
      throw StateError('Новые входы заблокированы после экстренной блокировки.');
    }
    authKeyPair = await AuthKeyPair.loadOrCreate();
    crypto = await CryptoService.loadOrCreate();
    final bundle = await crypto!.generatePublishableBundle();

    final result = await _api.loginWithPassword(
      identifier: identifier,
      password: password,
      deviceName: defaultTargetPlatform.name,
      deviceType: kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase(),
      authPublicKey: authKeyPair!.publicKeyBase64,
      identityKeyBundle: bundle,
    );
    await _finishLogin(result, identifier, checkLoginApproval: true);
  }

  Future<void> _finishLogin(
    Map<String, dynamic> result,
    String displayNameFallback, {
    bool checkLoginApproval = false,
  }) async {
    session = Session(
      userId: result['user_id'] as String,
      deviceId: result['device_id'] as String,
      accessToken: result['access_token'] as String,
      displayName: displayNameFallback,
    );
    _api.accessToken = session!.accessToken;
    await _sessionStore.save(
      userId: session!.userId,
      deviceId: session!.deviceId,
      accessToken: session!.accessToken,
      displayName: displayNameFallback,
    );
    knownDisplayNames[session!.userId] = displayNameFallback;

    await AccountSettingsScope.activate(session!.userId);

    try {
      await _api.getPreKeyBundle(session!.userId);
    } on ApiException catch (e) {
      DebugLog.instance.error('auth', 'account not on home node after login: ${e.statusCode}');
      await _sessionStore.clear();
      session = null;
      _api.accessToken = null;
      await AccountSettingsScope.deactivate();
      throw StateError(
        'Аккаунт не найден на Home Node (${AppConfig.homeNodeUrl}). '
        'Возможно, запущено два сервера на порту 8001 — остановите лишний и зарегистрируйтесь снова.',
      );
    }

    _connectRealtime();
    await _loadFavoritesPreferences();
    await _syncFavoritesChat();
    await refreshDevices();
    await _recordCurrentDeviceSessionMeta();
    await refreshConversations();

    if (checkLoginApproval && await LoginApprovalService.instance.isEnabled()) {
      await LoginApprovalService.instance.markDeviceAwaitingApproval(session!.deviceId);
      loginApprovalPending = true;
    } else {
      await _ensureCurrentDeviceTrusted();
      loginApprovalPending = await LoginApprovalService.instance.isDeviceAwaitingApproval(session!.deviceId);
      if (loginApprovalPending) {
        await _completeLoginApproval();
      }
    }

    DebugLog.instance.info('auth', 'logged in user=${session!.userId} device=${session!.deviceId}');
    await SecurityMetaStore.instance.recordLogin();
    _startTimeTasksTimer();
    unawaited(processTimeBasedTasks());
    notifyListeners();
  }

  void _startTimeTasksTimer() {
    _timeTasksTimer?.cancel();
    if (session == null) return;
    _timeTasksTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(processTimeBasedTasks());
    });
  }

  void _connectRealtime() {
    if (session == null) return;
    _realtime.connect(
      session!.accessToken,
      tokenProvider: () async {
        await _relogin();
        return session!.accessToken;
      },
    );
    _realtimeSub?.cancel();
    _realtimeSub = _realtime.messages.listen((event) {
      _realtimeEventChain = _realtimeEventChain
          .then((_) => _onRealtimeEvent(event))
          .catchError((Object e, StackTrace st) {
        debugPrint('Realtime event handling failed: $e\n$st');
      });
    });
  }

  /// Refresh token, WS, and conversation list after returning from background.
  Future<void> onAppResumed() async {
    if (session == null) return;
    await _relogin();
    _connectRealtime();
    await refreshConversations();
    unawaited(_replenishPrekeysIfNeeded());
    if (OutboxQueue.instance.isNotEmpty && websocketConnected) {
      unawaited(_drainOutboxQueue());
    }
    await _recordCurrentDeviceSessionMeta();
    await processTimeBasedTasks();
  }

  bool _outboxDrainPending = false;

  Future<void> _onRealtimeEvent(Map<String, dynamic> event) async {
    // On first realtime event after reconnect, drain the outbox queue.
    if (!_outboxDrainPending && OutboxQueue.instance.isNotEmpty) {
      _outboxDrainPending = true;
      unawaited(_drainOutboxQueue());
    }

    final type = event['type'] as String?;
    if (type == 'security_signal') {
      final fromUserId = event['from_user_id'] as String?;
      final code = event['event'] as int?;
      if (fromUserId != null && code != null) {
        await ingestSecuritySignal(fromUserId: fromUserId, event: code);
      }
      return;
    }
    if (type == 'typing') {
      final fromUserId = event['from_user_id'] as String?;
      final convId = event['conversation_id'] as String?;
      if (fromUserId != null && convId != null && fromUserId != session?.userId) {
        _setTyping(fromUserId, convId);
      }
      return;
    }
    if (type != 'new_message') return;
    final envelope = event['message'] as Map<String, dynamic>;
    final convId = envelope['conversation_id'] as String;

    final msg = ChatMessage(
      id: envelope['packet_id'] as String,
      conversationId: convId,
      senderUserId: envelope['sender_user_id'] as String,
      senderDeviceId: envelope['sender_device_id'] as String?,
      ciphertext: envelope['ciphertext'] as String,
      contentType: envelope['content_type'] as String? ?? 'text',
      cryptoVersion: envelope['crypto_version'] as String? ?? 'signal-v1',
      createdAt: DateTime.parse(envelope['created_at'] as String),
    );

    if (msg.contentType == 'login_approval_grant') {
      await _handleLoginApprovalSignal(msg);
      return;
    }
    if (msg.contentType == 'read_receipt') {
      await _handleReadReceipt(msg);
      return;
    }
    if (msg.contentType == 'sender_key_distribution') {
      await _processIncomingDistribution(msg);
      return; // control message — never shown as a chat bubble
    }
    if (CallSignalingService.isCallSignal(msg.contentType)) {
      await _handleIncomingCallSignal(msg);
      return; // control message — never shown as a chat bubble
    }

    if (msg.senderUserId != session?.userId) {
      if (await SettingsRuntime.instance.isBlocked(msg.senderUserId)) return;
      final isContact = isKnownContact(msg.senderUserId);
      final prior = messagesByConversation[convId];
      final weMessaged = prior?.any((m) => m.senderUserId == session?.userId) ?? false;
      if (!weMessaged &&
          !await SettingsRuntime.instance.incomingMessagesAllowed(
            msg.senderUserId,
            isContact: isContact,
          )) {
        DebugLog.instance.info('delivery', 'incoming message blocked by privacy.incoming_messages');
        return;
      }
    }

    final list = messagesByConversation.putIfAbsent(convId, () => []);
    if (list.any((m) => m.id == msg.id)) return;
    if (_absorbOutgoingEcho(list, msg)) return;

    await _decryptInPlace(msg);

    list.add(msg);
    await _persistMessage(msg);
    if (activeConversationId == convId) {
      await markConversationRead(convId);
    } else {
      await recomputeUnread(convId);
    }
    _maybeNotifyMessage(msg, convId);
    await refreshConversations();
    notifyListeners();
  }

  void _maybeNotifyMessage(ChatMessage msg, String convId) {
    if (msg.isSecret || msg.systemKind != null || msg.duressCode != null) return;

    final settings = notificationSettings;
    if (settings == null || session == null) return;
    final conv = _findConversation(convId);
    if (conv == null) return;

    if (_secretHiddenConversationIds.contains(convId) && hiddenChatsSilenceNotifications) {
      return;
    }

    final isHidden = isSecretHidden(convId);
    final isPrivateHidden = _hiddenConversationIds.contains(convId);
    final isContact = knownDisplayNames.containsKey(msg.senderUserId);
    if (!settings.shouldNotifyMessage(
      conversation: conv,
      message: msg,
      activeConversationId: activeConversationId,
      myUserId: session!.userId,
      myDisplayName: session!.displayName,
      isKnownContact: isContact,
      isHiddenChat: isHidden,
      isPrivateHiddenChat: isPrivateHidden,
    )) {
      return;
    }

    final sender = labelFor(msg.senderUserId);
    final forceGeneric = isHidden && settings.hiddenChatPolicy == 'generic';
    final body = settings.bodyForMessage(
      message: msg,
      senderLabel: sender,
      isGroup: conv.isGroup,
      forceGeneric: forceGeneric,
    );
    InAppNotificationService.instance.notify(
      InAppNotificationEvent(
        title: settings.titleForSender(sender),
        body: body,
        playSound: settings.sounds,
        vibrate: settings.vibration,
        conversationId: convId,
      ),
    );
    OsNotificationService.instance.show(
      title: settings.titleForSender(sender),
      body: body,
      conversationId: convId,
    );
  }

  void _maybeNotifyIncomingCall(String peerUserId) {
    final settings = notificationSettings;
    if (settings == null) return;
    final isContact = knownDisplayNames.containsKey(peerUserId);
    if (!settings.shouldNotifyIncomingCall(isKnownContact: isContact)) return;

    InAppNotificationService.instance.notify(
      InAppNotificationEvent(
        title: labelFor(peerUserId),
        body: 'Входящий звонок',
        playSound: settings.sounds,
        vibrate: settings.vibration,
      ),
    );
    OsNotificationService.instance.show(
      title: labelFor(peerUserId),
      body: 'Входящий звонок',
    );
  }

  /// A sender-key distribution arrives pairwise-encrypted (1:1 session,
  /// see 0301_GROUP_MESSAGING.md → Распространение sender key), never as
  /// group ciphertext, regardless of which conversation carried it.
  Future<void> _processIncomingDistribution(ChatMessage msg) async {
    if (msg.senderUserId == session?.userId) return; // don't process our own
    await _cryptoDecryptQueue.run('direct:${msg.senderUserId}', () async {
      try {
        final plaintextBytes = await crypto!.decrypt(msg.senderUserId, msg.ciphertext);
        final payload = jsonDecode(utf8.decode(plaintextBytes)) as Map<String, dynamic>;
        await crypto!.processGroupSenderKeyDistribution(
          payload['group_id'] as String,
          msg.senderUserId,
          payload['distribution'] as String,
        );
      } catch (_) {
        // Non-fatal: a missed/garbled distribution just means we can't decrypt
        // that sender's group messages until they redistribute (e.g. next send).
      }
    });
  }

  /// Applies an incoming call-signaling message to [currentCall] — see
  /// spec/0303_CALLS.md, ADR-0008.
  Future<void> _handleIncomingCallSignal(ChatMessage msg) async {
    if (msg.senderUserId == session?.userId) return; // don't process our own
    CallSignal signal;
    try {
      signal = await _callSignaling.decode(senderUserId: msg.senderUserId, contentType: msg.contentType, ciphertext: msg.ciphertext);
    } catch (_) {
      return; // undecryptable/garbled signal — non-fatal, mirrors _processIncomingDistribution
    }

    switch (signal.type) {
      case CallSignalType.offer:
        if (DateTime.now().difference(msg.createdAt) > _callOfferMaxAge) return;
        final existing = currentCall;
        if (existing != null) {
          if (existing.callId == signal.callId) return; // duplicate/retried offer
          try {
            await _sendCallSignal(
              peerUserId: msg.senderUserId,
              contentType: CallSignalType.busy.contentType,
              ciphertext: await _callSignaling.encodeBusy(peerUserId: msg.senderUserId, callId: signal.callId),
            );
          } catch (_) {
            // best-effort — worst case the caller's offer just times out on their side
          }
          return;
        }
        final allowed = await SettingsRuntime.instance.callsAllowed(
          msg.senderUserId,
          isContact: isKnownContact(msg.senderUserId),
        );
        if (!allowed) {
          try {
            await _sendCallSignal(
              peerUserId: msg.senderUserId,
              contentType: CallSignalType.reject.contentType,
              ciphertext: await _callSignaling.encodeReject(
                peerUserId: msg.senderUserId,
                callId: signal.callId,
              ),
            );
          } catch (_) {}
          return;
        }
        currentCall = ActiveCall(
          callId: signal.callId,
          peerUserId: msg.senderUserId,
          kind: signal.kind ?? CallKind.audio,
          outgoing: false,
          remoteSdp: signal.sdp,
        );
        if (trustLevelFor(msg.senderUserId) == TrustLevel.unknown) {
          unawaited(SecurityLogService.instance.append(
            SecurityEvent(
              title: 'Звонок от неизвестного контакта',
              subtitle: labelFor(msg.senderUserId),
              at: DateTime.now(),
              icon: 'call',
            ),
          ));
        }
        _maybeNotifyIncomingCall(msg.senderUserId);
      case CallSignalType.answer:
        final call = currentCall;
        if (call == null || call.callId != signal.callId || !call.outgoing || call.media == null) return;
        call.remoteSdp = signal.sdp;
        await call.media!.applyRemoteAnswer(signal.sdp!);
        call.answered = true;
        call.answeredAt = DateTime.now();
      case CallSignalType.iceCandidate:
        final call = currentCall;
        if (call == null || call.callId != signal.callId || signal.candidate == null) return;
        if (call.media != null) {
          await call.media!.addRemoteIceCandidate(signal.candidate!);
        } else {
          call.pendingRemoteIceCandidates.add(signal.candidate!);
        }
      case CallSignalType.reject:
      case CallSignalType.cancel:
      case CallSignalType.end:
      case CallSignalType.busy:
        final call = currentCall;
        if (call != null && call.callId == signal.callId) {
          final status = switch (signal.type) {
            CallSignalType.reject => CallHistoryStatus.rejected,
            CallSignalType.cancel => call.outgoing ? CallHistoryStatus.cancelled : CallHistoryStatus.missed,
            CallSignalType.end => CallHistoryStatus.completed,
            CallSignalType.busy => CallHistoryStatus.busy,
            _ => CallHistoryStatus.failed,
          };
          await _finalizeCall(call, status);
        }
    }
    notifyListeners();
  }

  Future<void> refreshConversations() async {
    final raw = await _api.listConversations();
    final me = session?.userId;
    final next = <Conversation>[];
    for (final j in raw) {
      final map = j as Map<String, dynamic>;
      final conv = Conversation.fromJson(map);
      if (conv.isGroup && me != null && !_locallyCreatedGroupIds.contains(conv.id)) {
        final others = conv.participantUserIds.where((id) => id != me);
        var allowed = false;
        for (final peer in others) {
          final isContact = contactTrustLevels[peer] != null &&
              contactTrustLevels[peer] != TrustLevel.unknown;
          if (await SettingsRuntime.instance.groupInviteAllowed(peer, isContact: isContact)) {
            allowed = true;
            break;
          }
        }
        if (!allowed && others.isNotEmpty) {
          DebugLog.instance.info('chat', 'group ${conv.id} ignored by privacy.group_invites');
          continue;
        }
      }
      next.add(conv);
      final names = map['participant_display_names'] as Map<String, dynamic>?;
      names?.forEach((uid, name) {
        final id = uid.toString();
        if (!isValidUserIdFormat(id)) return;
        if (name != null) knownDisplayNames[id] = name as String;
      });
    }
    conversations = next;
    // Aliases are local-only; also sanitize to UUID keys.
    _contactAliases.forEach((uid, label) {
      if (!isValidUserIdFormat(uid)) return;
      knownDisplayNames[uid] = label;
    });
    _sortConversations();
    await recomputeAllUnread();
    await validateAllConversationsReachability();
    _ensureTrustForConversationPeers();
    DebugLog.instance.info('session', 'user=$me conversations=${conversations.length}');
    for (final c in conversations) {
      if (c.isGroup) continue;
      final peer = directPeerUserId(c);
      final ok = conversationReachable[c.id] == true;
      DebugLog.instance.info('chat', '${c.id.substring(0, 8)}… peer=$peer reachable=$ok');
    }
    lastConversationSyncAt = DateTime.now();
    await SettingsRuntime.instance.markLastSync(lastConversationSyncAt);
    notifyListeners();
  }

  void _ensureTrustForConversationPeers() {
    final me = session?.userId;
    if (me == null) return;
    for (final c in conversations) {
      for (final uid in c.participantUserIds) {
        if (uid == me) continue;
        final current = contactTrustLevels[uid];
        if (current == null || current == TrustLevel.unknown) {
          contactTrustLevels[uid] = TrustLevel.normal;
        }
      }
    }
  }

  Future<ConnectionStatusSnapshot> probeConnectionStatus() {
    return _connectionStatus.probeAll(
      websocketConnected: websocketConnected,
      lastConversationSyncAt: lastConversationSyncAt,
    );
  }

  /// Reconnect WebSocket and refresh session data (for Connection Status UI).
  Future<void> reconnectConnection() => onAppResumed();

  /// Drain the outbox queue — send queued messages in order once online.
  Future<void> _drainOutboxQueue() async {
    final entries = List<OutboxEntry>.from(OutboxQueue.instance.entries);
    for (final entry in entries) {
      if (!websocketConnected) break; // Stop if we go offline again
      try {
        final conversation = _findConversation(entry.conversationId);
        if (conversation == null) {
          // Conversation not found — drop the entry
          await OutboxQueue.instance.remove(entry.id);
          await MessageDeliveryStore.instance.setStatus(entry.id, MessageDeliveryStatus.failed, error: 'Conversation not found');
          continue;
        }
        // Update UI status to sending
        await MessageDeliveryStore.instance.setStatus(entry.id, MessageDeliveryStatus.sending);
        notifyListeners();

        final wireBody = MessagePayload.encodeText(
          body: entry.text,
          secret: entry.secret,
          replyToMessageId: entry.replyToMessageId,
          replyPreview: entry.replyPreview,
          ttlSeconds: entry.ttlSeconds,
        );
        final ciphertext = await _encryptForConversation(conversation, Uint8List.fromList(utf8.encode(wireBody)));
        final resp = await _api.sendMessage(
          conversationId: conversation.id,
          ciphertext: ciphertext,
          contentType: 'text',
          clientMsgId: entry.id,
        );

        await OutboxQueue.instance.remove(entry.id);
        final msg = ChatMessage.fromJson(resp)
          ..plaintext = entry.text
          ..replyToMessageId = entry.replyToMessageId
          ..replyPreview = entry.replyPreview
          ..isSecret = entry.secret
          ..ttlSeconds = entry.ttlSeconds;
        final list = messagesByConversation[conversation.id]!;
        final idx = list.indexWhere((m) => m.id == entry.id);
        if (idx >= 0) {
          list[idx] = msg;
        }
        await MessageDeliveryStore.instance.setStatus(msg.id, MessageDeliveryStatus.sent);
        await _persistMessage(msg);
        notifyListeners();
      } catch (e) {
        DebugLog.instance.warn('outbox', 'Failed to send queued message ${entry.id}: $e');
        await MessageDeliveryStore.instance.setStatus(entry.id, MessageDeliveryStatus.failed, error: e.toString());
        await OutboxQueue.instance.remove(entry.id);
        notifyListeners();
      }
    }
    _outboxDrainPending = false;
  }

  /// Replenish one-time prekeys on the server if the local count is low.
  /// Called at boot and after app resumes. Silent failure is intentional —
  /// the next replenishment attempt will happen on next startup.
  Future<void> _replenishPrekeysIfNeeded() async {
    final c = crypto;
    final s = session;
    if (c == null || s == null) return;
    try {
      final local = c.countLocalPreKeys();
      if (local >= CryptoService.prekeyLowWatermark) return;
      final needed = CryptoService.prekeyReplenishTarget - local;
      DebugLog.instance.info('prekey', 'Low prekeys ($local), replenishing $needed...');
      final batch = await c.generateReplenishmentBatch(count: needed);
      final result = await _api.uploadPrekeys(s.deviceId, batch);
      DebugLog.instance.info('prekey', 'Replenished: server now has ${result['unused_prekeys']} prekeys');
    } catch (e) {
      DebugLog.instance.warn('prekey', 'Replenishment failed: $e');
    }
  }

  /// Returns true when messages can be sent immediately or queued for later.
  bool get canSendMessages => session != null;

  /// Returns true when there is an active realtime channel for immediate delivery.
  bool get canSendImmediately => session != null && websocketConnected;

  int get failedOutboundCount {
    var count = 0;
    for (final list in messagesByConversation.values) {
      for (final m in list) {
        final info = MessageDeliveryStore.instance.infoFor(m.id);
        if (info?.status == MessageDeliveryStatus.failed) count++;
      }
    }
    return count;
  }

  int get secretHiddenChatCount => _secretHiddenConversationIds.length;

  void _sortConversations() {
    conversations.sort((a, b) => _conversationActivity(b).compareTo(_conversationActivity(a)));
  }

  DateTime _conversationActivity(Conversation c) {
    final msgs = messagesByConversation[c.id];
    if (msgs != null && msgs.isNotEmpty) return msgs.last.createdAt;
    return c.updatedAt;
  }

  List<Conversation> get sortedConversations {
    final copy = conversations
        .where((c) => !_hiddenConversationIds.contains(c.id) && !_secretHiddenConversationIds.contains(c.id))
        .toList();
    copy.sort((a, b) => _conversationActivity(b).compareTo(_conversationActivity(a)));
    return copy;
  }

  /// Chats for the main list — optionally includes local «Избранное» at the top.
  /// In decoy mode, filters to [security.fake_profile_chats] when non-empty.
  List<Conversation> get conversationsForList {
    var list = sortedConversations;
    if (AppPrivacySession.instance.isInDecoyMode && _fakeProfileChatIds.isNotEmpty) {
      final allow = _fakeProfileChatIds.toSet();
      list = list.where((c) => allow.contains(c.id)).toList();
    }
    final fav = visibleFavoritesConversation;
    if (fav == null) return list;
    if (AppPrivacySession.instance.isInDecoyMode && _fakeProfileChatIds.isNotEmpty) {
      if (!_fakeProfileChatIds.contains(fav.id)) return list;
    }
    return [fav, ...list];
  }

  Future<void> reloadFakeProfileChats() async {
    _fakeProfileChatIds = await SettingsRuntime.instance.fakeProfileChats();
    notifyListeners();
  }

  /// Conversations matching [query] for the main list search bar.
  /// When [hidden.hide_from_search] is false, secret-hidden chats are included.
  List<Conversation> conversationsMatchingSearch(String query) {
    final q = query.trim().toLowerCase();
    final base = conversationsForList;
    final pool = <Conversation>[...base];
    if (!hiddenChatsExcludeFromSearch && hiddenChatsEnabled) {
      for (final c in secretHiddenConversations) {
        if (!pool.any((x) => x.id == c.id)) pool.add(c);
      }
    }
    if (q.isEmpty) return pool;
    return pool.where((c) => conversationTitle(c).toLowerCase().contains(q)).toList();
  }

  Conversation? get visibleFavoritesConversation {
    if (!favoritesChatEnabled || session == null) return null;
    final msgs = messagesByConversation[FavoritesChat.id];
    if (msgs == null || msgs.isEmpty) return null;
    final updated = msgs.last.createdAt;
    return FavoritesChat.conversation(userId: session!.userId, updatedAt: updated);
  }

  int get favoritesCount => messagesByConversation[FavoritesChat.id]?.length ?? 0;

  Future<void> _loadFavoritesPreferences() async {
    favoritesChatEnabled = await FavoritesPreferencesStore.instance.isChatEnabled();
  }

  Future<void> setFavoritesChatEnabled(bool enabled) async {
    favoritesChatEnabled = enabled;
    await FavoritesPreferencesStore.instance.setChatEnabled(enabled);
    notifyListeners();
  }

  Future<void> _syncFavoritesChat() async {
    final items = await FavoritesStore.instance.loadAll();
    final msgs = items.map(FavoritesChat.toChatMessage).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    messagesByConversation[FavoritesChat.id] = msgs;
  }

  Future<void> refreshFavoritesChat() => _syncFavoritesChat();

  Future<void> removeFavorite(String favoriteId) async {
    await FavoritesStore.instance.remove(favoriteId);
    await _syncFavoritesChat();
    notifyListeners();
  }

  Conversation? conversationById(String id) {
    if (FavoritesChat.isId(id)) return visibleFavoritesConversation;
    return _findConversation(id);
  }

  List<Conversation> get secretHiddenConversations {
    final copy = conversations.where((c) => _secretHiddenConversationIds.contains(c.id)).toList();
    if (hiddenChatsSort == HiddenChatSort.name) {
      copy.sort((a, b) => conversationTitle(a).compareTo(conversationTitle(b)));
    } else {
      copy.sort((a, b) => _conversationActivity(b).compareTo(_conversationActivity(a)));
    }
    return copy;
  }

  bool isSecretHidden(String conversationId) => _secretHiddenConversationIds.contains(conversationId);

  bool isLocallyHidden(String conversationId) => _hiddenConversationIds.contains(conversationId);

  Future<void> scheduleTextMessage({
    required Conversation conversation,
    required String text,
    required DateTime sendAt,
    String? replyToMessageId,
    String? replyPreview,
  }) async {
    final item = ScheduledMessage(
      id: _uuid.v4(),
      conversationId: conversation.id,
      text: text.trim(),
      sendAt: sendAt,
      createdAt: DateTime.now(),
      replyToMessageId: replyToMessageId,
      replyPreview: replyPreview,
    );
    await ScheduledMessageStore.instance.save(item);
    scheduledMessageCount = (await ScheduledMessageStore.instance.loadAll()).length;
    notifyListeners();
  }

  Future<void> cancelScheduledMessage(String id) async {
    await ScheduledMessageStore.instance.remove(id);
    scheduledMessageCount = (await ScheduledMessageStore.instance.loadAll()).length;
    notifyListeners();
  }

  Future<void> addFavoriteMessage(Conversation conversation, ChatMessage message) async {
    final me = session?.userId;
    final senderLabel = message.senderUserId == me
        ? 'Вы'
        : labelFor(message.senderUserId);
    final item = FavoriteItem(
      id: _uuid.v4(),
      conversationId: conversation.id,
      conversationTitle: conversationTitle(conversation),
      messageId: message.id,
      contentType: message.contentType,
      preview: messagePreview(message),
      savedAt: DateTime.now(),
      senderUserId: message.senderUserId,
      senderLabel: senderLabel,
    );
    await FavoritesStore.instance.save(item);
    await _syncFavoritesChat();
    notifyListeners();
  }

  Future<void> addMessageReminder({
    required Conversation conversation,
    required ChatMessage message,
    required DateTime remindAt,
  }) async {
    final reminder = MessageReminder(
      id: _uuid.v4(),
      conversationId: conversation.id,
      messageId: message.id,
      preview: messagePreview(message),
      remindAt: remindAt,
    );
    await MessageReminderStore.instance.save(reminder);
    notifyListeners();
  }

  Future<void> processTimeBasedTasks() async {
    if (session == null) return;
    await _processDueScheduledMessages();
    await _processDueReminders();
    scheduledMessageCount = (await ScheduledMessageStore.instance.loadAll()).length;
  }

  Future<void> _processDueScheduledMessages() async {
    final now = DateTime.now();
    final due = (await ScheduledMessageStore.instance.loadAll()).where((m) => !m.sendAt.isAfter(now)).toList();
    for (final item in due) {
      final conv = _findConversation(item.conversationId);
      if (conv == null) {
        await ScheduledMessageStore.instance.remove(item.id);
        continue;
      }
      try {
        await sendText(
          conv,
          item.text,
          replyToMessageId: item.replyToMessageId,
          replyPreview: item.replyPreview,
        );
        await ScheduledMessageStore.instance.remove(item.id);
      } catch (e) {
        DebugLog.instance.error('schedule', 'failed ${item.id}: $e');
      }
    }
  }

  Future<void> _processDueReminders() async {
    final now = DateTime.now();
    final due = (await MessageReminderStore.instance.loadAll()).where((r) => !r.remindAt.isAfter(now)).toList();
    for (final reminder in due) {
      await _applyReminder(reminder);
      await MessageReminderStore.instance.remove(reminder.id);
    }
  }

  Future<void> _applyReminder(MessageReminder reminder) async {
    final msgs = messagesByConversation[reminder.conversationId] ?? [];
    final target = msgs.where((m) => m.id == reminder.messageId).firstOrNull;
    if (target != null) {
      final before = target.createdAt.subtract(const Duration(seconds: 1));
      await _chatPrefs.setLastRead(reminder.conversationId, before);
      await recomputeUnread(reminder.conversationId);
    } else {
      unreadCounts[reminder.conversationId] = (unreadCounts[reminder.conversationId] ?? 0) + 1;
    }
    final conv = _findConversation(reminder.conversationId);
    final title = conv != null ? conversationTitle(conv) : 'Напоминание';
    InAppNotificationService.instance.notify(
      InAppNotificationEvent(
        title: title,
        body: reminder.preview,
        playSound: notificationSettings?.sounds ?? true,
        vibrate: notificationSettings?.vibration ?? true,
        conversationId: reminder.conversationId,
      ),
    );
    notifyListeners();
  }

  Future<void> _loadHiddenChatsPolicies() async {
    final runtime = SettingsRuntime.instance;
    hiddenChatsEnabled = await runtime.hiddenEnabled();
    hiddenChatsOpenMethod = await runtime.hiddenOpenMethod();
    hiddenChatsExcludeFromSearch = await runtime.hiddenHideFromSearch();
    hiddenChatsSilenceNotifications = await runtime.hiddenHideNotifications();
    hiddenChatsHideMedia = await runtime.hiddenHideMedia();
    hiddenChatsSort = await HiddenChatsStore.instance.sortOrder();
    await _loadPrivacyPolicies();
  }

  Future<void> _loadPrivacyPolicies() async {
    final runtime = SettingsRuntime.instance;
    privacyOnlineStatusEnabled = await runtime.onlineStatusEnabled();
    privacyInvisibleMode = await runtime.invisibleMode();
    privacyLastSeenPolicy = await runtime.lastSeenPolicy();
    privacyLastSeenList = (await CatalogListStore().load('privacy.last_seen_list')).toSet();
    privacyTypingEnabled = await runtime.typingEnabled();
    privacyReadReceiptsVisible = await runtime.readReceiptsVisible();
  }

  Future<void> refreshHiddenChatsPolicies() async {
    await _loadHiddenChatsPolicies();
    notifyListeners();
  }

  /// Reload privacy.* caches after catalog edits.
  Future<void> refreshPrivacyRuntime() async {
    await _loadPrivacyPolicies();
    notifyListeners();
  }

  bool isKnownContact(String userId) =>
      knownDisplayNames.containsKey(userId) ||
      (contactTrustLevels[userId] != null && contactTrustLevels[userId] != TrustLevel.unknown);

  bool _visibilityAllowsSync(String policy, Set<String> list, String viewerUserId) {
    return switch (policy) {
      'nobody' => false,
      'contacts' => isKnownContact(viewerUserId),
      'selected' => list.contains(viewerUserId),
      'everyone' => true,
      _ => isKnownContact(viewerUserId),
    };
  }

  /// Mutual-style: show peer presence only when we would share ours with them.
  bool canShowOnlineStatusFor(String peerUserId) {
    if (privacyInvisibleMode || !privacyOnlineStatusEnabled) return false;
    return _visibilityAllowsSync(privacyLastSeenPolicy, privacyLastSeenList, peerUserId);
  }

  bool canShowLastSeenFor(String peerUserId) {
    if (privacyInvisibleMode) return false;
    return _visibilityAllowsSync(privacyLastSeenPolicy, privacyLastSeenList, peerUserId);
  }

  /// Sends typing indicator to server over WebSocket.
  Future<void> notifyTyping(String conversationId) async {
    if (!privacyTypingEnabled) return;
    if (!await SettingsRuntime.instance.typingEnabled()) return;
    if (!websocketConnected) return;
    _realtime.send({
      'type': 'typing',
      'conversation_id': conversationId,
    });
  }

  /// Voice-recording status to peers — gated by privacy.voice_record_status.
  Future<void> notifyVoiceRecording(String conversationId) async {
    if (!await SettingsRuntime.instance.voiceRecordStatusEnabled()) return;
    if (!websocketConnected) return;
    _realtime.send({
      'type': 'typing', // reuse typing channel, UI shows "recording…" separately
      'conversation_id': conversationId,
      'kind': 'voice',
    });
  }

  /// Whether the UI may show "recording…" to the local user / peers.
  Future<bool> voiceRecordStatusVisible() =>
      SettingsRuntime.instance.voiceRecordStatusEnabled();

  Future<void> reloadSecretHiddenFromStore() async {
    _secretHiddenConversationIds
      ..clear()
      ..addAll(await HiddenChatsStore.instance.loadSecretHiddenIds());
    await CatalogListStore().save(
      'hidden.chat_list',
      _secretHiddenConversationIds.toList(),
    );
    await _loadHiddenChatsPolicies();
    notifyListeners();
  }

  Future<void> hideConversationAsSecret(String conversationId) async {
    if (!await SettingsRuntime.instance.hiddenEnabled()) {
      throw StateError('Скрытые чаты отключены');
    }
    _secretHiddenConversationIds.add(conversationId);
    await HiddenChatsStore.instance.addSecretHidden(conversationId);
    await CatalogListStore().save(
      'hidden.chat_list',
      _secretHiddenConversationIds.toList(),
    );
    if (activeConversationId == conversationId) activeConversationId = null;
    notifyListeners();
  }

  Future<void> unhideConversation(String conversationId) async {
    _secretHiddenConversationIds.remove(conversationId);
    await HiddenChatsStore.instance.removeSecretHidden(conversationId);
    await CatalogListStore().save(
      'hidden.chat_list',
      _secretHiddenConversationIds.toList(),
    );
    notifyListeners();
  }

  Future<void> hideConversationLocally(String conversationId) async {
    _hiddenConversationIds.add(conversationId);
    await _localSettings.setStringList('hidden_conversations', _hiddenConversationIds.toList());
    messagesByConversation.remove(conversationId);
    if (activeConversationId == conversationId) activeConversationId = null;
    notifyListeners();
  }

  ChatMessage? lastMessageFor(String conversationId) {
    final msgs = messagesByConversation[conversationId];
    if (msgs == null || msgs.isEmpty) return null;
    return msgs.last;
  }

  /// Last message shown in the chat list subtitle (skips secret when mode is off).
  ChatMessage? lastMessageForListPreview(String conversationId) {
    final msgs = messagesByConversation[conversationId];
    if (msgs == null || msgs.isEmpty) return null;
    if (isSecretSessionActive(conversationId)) return msgs.last;
    for (var i = msgs.length - 1; i >= 0; i--) {
      if (!msgs[i].isSecret) return msgs[i];
    }
    return null;
  }

  bool isSecretSessionActive(String conversationId) => _secretSessionActive.contains(conversationId);

  Future<bool> tryActivateSecretSession(String conversationId, String password) async {
    if (AppPrivacySession.instance.isInDecoyMode) return false;
    if (!await PinSecurity.isRealPinConfigured()) return false;
    if (!await SecretChatSecurity.isConfigured()) return false;
    if (!await SecretChatSecurity.verify(password)) return false;
    activateSecretSession(conversationId);
    return true;
  }

  void activateSecretSession(String conversationId) {
    if (AppPrivacySession.instance.isInDecoyMode) return;
    _secretSessionActive.add(conversationId);
    _unsealSecretMessages(conversationId);
    _resetSecretSessionTimer(conversationId);
    notifyListeners();
  }

  void deactivateSecretSession(String conversationId) {
    if (!_secretSessionActive.remove(conversationId)) return;
    _secretSessionTimers.remove(conversationId)?.cancel();
    _sealSecretMessagesInConversation(conversationId);
    notifyListeners();
  }

  void _sealSecretMessage(ChatMessage m) {
    if (!m.isSecret || isSecretSessionActive(m.conversationId)) return;
    final body = m.plaintext;
    if (body == null || body.isEmpty) return;
    _secretPlaintextVault[m.id] = body;
    m.plaintext = null;
  }

  void _sealSecretMessagesInConversation(String conversationId) {
    final list = messagesByConversation[conversationId];
    if (list == null) return;
    for (final m in list) {
      _sealSecretMessage(m);
    }
    final userId = session?.userId;
    if (userId != null) {
      _messageCache.upsertMessages(userId, list).catchError((_) {});
    }
  }

  void _unsealSecretMessages(String conversationId) {
    final list = messagesByConversation[conversationId];
    if (list == null) return;
    var changed = false;
    for (final m in list) {
      if (!m.isSecret) continue;
      final stored = _secretPlaintextVault.remove(m.id);
      if (stored != null) {
        m.plaintext = stored;
        m.decryptFailed = false;
        MessagePayload.applyTo(m);
        changed = true;
      }
    }
    if (changed) {
      final userId = session?.userId;
      if (userId != null) {
        _messageCache.upsertMessages(userId, list).catchError((_) {});
      }
    }
  }

  void touchSecretSession(String conversationId) {
    if (!isSecretSessionActive(conversationId)) return;
    _resetSecretSessionTimer(conversationId);
  }

  void _resetSecretSessionTimer(String conversationId) {
    _secretSessionTimers[conversationId]?.cancel();
    SecretChatPreferencesStore.instance.sessionTimeoutMinutes().then((minutes) {
      if (!_secretSessionActive.contains(conversationId)) return;
      _secretSessionTimers[conversationId] = Timer(Duration(minutes: minutes), () {
        deactivateSecretSession(conversationId);
      });
    });
  }

  Future<void> loadSecretChatPreferences() async {
    var seconds = await SecretChatPreferencesStore.instance.secretDisappearingSeconds();
    // Catalog auto-delete overlaps secret disappearing when the secret-specific
    // preference is off — apply catalog TTL as the effective secret TTL.
    if (seconds == null && await SettingsRuntime.instance.autoDeleteEnabled()) {
      seconds = await SettingsRuntime.instance.outgoingAutoDeleteSeconds();
    }
    secretDisappearingSeconds = seconds;
    notifyListeners();
  }

  Conversation? directConversationWith(String peerUserId) {
    for (final c in conversations) {
      if (c.isGroup) continue;
      if (c.participantUserIds.contains(peerUserId)) return c;
    }
    return null;
  }

  Future<void> purgeAllSecretMessages() async {
    final userId = session?.userId;
    for (final entry in messagesByConversation.entries.toList()) {
      final kept = entry.value.where((m) => !m.isSecret).toList();
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
    notifyListeners();
  }

  void deactivateSecretSessionForAll() {
    for (final id in _secretSessionActive.toList()) {
      deactivateSecretSession(id);
    }
  }

  Future<void> sendDuressSignalToTrusted({
    required int code,
    DuressTrigger? trigger,
    List<String>? channelsOverride,
  }) async {
    if (!await SettingsRuntime.instance.distressSignalEnabled()) {
      DebugLog.instance.info('duress', 'distress_signal disabled — skip send');
      return;
    }
    List<String> trusted;
    List<String> channels;
    final distress = await SettingsRuntime.instance.distressContacts();
    if (distress.isNotEmpty) {
      trusted = distress;
      channels = channelsOverride ?? ['chat'];
    } else if (DuressPolicySession.instance.isUnlocked) {
      final data = DuressPolicySession.instance.data;
      trusted = data?.trustedUserIds ?? [];
      channels = channelsOverride ?? data?.trustedChannels ?? ['chat'];
    } else {
      final mirror = await DuressRuntimeStore.instance.loadMirror();
      trusted = mirror.trustedUserIds;
      channels = channelsOverride ?? mirror.trustedChannels;
    }
    if (trusted.isEmpty) return;
    if (!_duressChannelEnabled(channels, 'chat')) return;
    var sent = false;
    for (final peerId in trusted) {
      final conv = directConversationWith(peerId);
      if (conv == null) continue;
      await _sendDuressMessage(conv, code: code);
      sent = true;
    }
    if (sent) {
      await DuressAuditService.instance.recordOutbound(code: code, channel: 'chat', trigger: trigger);
    }
  }

  Future<void> relaySecuritySignal({
    required int event,
    DuressTrigger? trigger,
    List<String>? channelsOverride,
  }) async {
    List<String> trusted;
    List<String> channels;
    if (DuressPolicySession.instance.isUnlocked) {
      final data = DuressPolicySession.instance.data;
      trusted = data?.trustedUserIds ?? [];
      channels = channelsOverride ?? data?.trustedChannels ?? ['relay'];
    } else {
      final mirror = await DuressRuntimeStore.instance.loadMirror();
      trusted = mirror.trustedUserIds;
      channels = channelsOverride ?? mirror.trustedChannels;
    }
    if (trusted.isEmpty || !_duressChannelEnabled(channels, 'relay')) return;
    if (!await DuressRateLimiter.instance.allowRelay()) {
      if (_duressChannelEnabled(channels, 'chat')) {
        await sendDuressSignalToTrusted(code: event, trigger: trigger);
      }
      return;
    }
    final ok = await SecuritySignalClient(_api).relay(event: event, targets: trusted);
    if (ok) {
      await DuressAuditService.instance.recordOutbound(code: event, channel: 'relay', trigger: trigger);
    } else if (_duressChannelEnabled(channels, 'chat')) {
      await sendDuressSignalToTrusted(code: event, trigger: trigger);
    }
  }

  /// Sends test code 90 via configured trusted channels (chat and/or relay).
  Future<String> testDuressDelivery({int code = 90}) async {
    List<String> trusted;
    List<String> channels;
    if (DuressPolicySession.instance.isUnlocked) {
      final data = DuressPolicySession.instance.data;
      trusted = data?.trustedUserIds ?? [];
      channels = data?.trustedChannels ?? ['chat', 'relay'];
    } else {
      final mirror = await DuressRuntimeStore.instance.loadMirror();
      trusted = mirror.trustedUserIds;
      channels = mirror.trustedChannels;
    }
    if (trusted.isEmpty) return 'Добавьте доверенные контакты';

    final parts = <String>[];
    if (_duressChannelEnabled(channels, 'chat')) {
      await sendDuressSignalToTrusted(code: code);
      parts.add('чат');
    }
    if (_duressChannelEnabled(channels, 'relay')) {
      await relaySecuritySignal(event: code);
      final last = await DuressAuditService.instance.lastOutbound();
      if (last?.code == code && last?.channel == 'relay') {
        parts.add('relay');
      } else if (last?.code == code && last?.channel == 'chat' && !parts.contains('чат')) {
        parts.add('чат (fallback)');
      } else {
        parts.add('relay не доставлен');
      }
    }
    if (parts.isEmpty) return 'Каналы доставки не выбраны';
    return 'Код $code: ${parts.join(', ')}';
  }

  bool _duressChannelEnabled(List<String> channels, String channel) {
    if (channels.contains('both')) return true;
    return channels.contains(channel);
  }

  Future<void> ingestSecuritySignal({required String fromUserId, required int event}) async {
    if (session == null) return;
    final conv = directConversationWith(fromUserId);
    if (conv == null) return;

    final wireBody = MessagePayload.encodeDuress(code: event);
    final msg = ChatMessage(
      id: 'duress-ws-${DateTime.now().millisecondsSinceEpoch}',
      conversationId: conv.id,
      senderUserId: fromUserId,
      senderDeviceId: null,
      ciphertext: '',
      contentType: 'text',
      cryptoVersion: 'local-duress',
      createdAt: DateTime.now(),
      plaintext: wireBody,
    );
    MessagePayload.applyTo(msg);
    final list = messagesByConversation.putIfAbsent(conv.id, () => []);
    list.add(msg);
    await _persistMessage(msg);
    if (activeConversationId == conv.id) {
      await markConversationRead(conv.id);
    }
    notifyListeners();
  }

  Future<void> _sendDuressMessage(Conversation conversation, {required int code}) async {
    if (session == null) return;
    final wireBody = MessagePayload.encodeDuress(code: code);
    try {
      final ciphertext = await _encryptForConversation(conversation, Uint8List.fromList(utf8.encode(wireBody)));
      final resp = await _api.sendMessage(
        conversationId: conversation.id,
        ciphertext: ciphertext,
        contentType: 'text',
      );
      final msg = ChatMessage.fromJson(resp)..plaintext = wireBody;
      MessagePayload.applyTo(msg);
      final list = messagesByConversation.putIfAbsent(conversation.id, () => []);
      if (!list.any((m) => m.id == msg.id)) {
        list.add(msg);
        await _persistMessage(msg);
      }
      notifyListeners();
    } catch (e) {
      DebugLog.instance.error('duress', 'system alert failed: $e');
    }
  }

  Future<void> loadChatPreferences(String conversationId) async {
    chatMuted[conversationId] = await _chatPrefs.isMuted(conversationId);
    disappearingSeconds[conversationId] = await _chatPrefs.getDisappearingSeconds(conversationId);
    notifyListeners();
  }

  void setActiveConversation(String? conversationId) {
    if (activeConversationId != null && activeConversationId != conversationId) {
      deactivateSecretSession(activeConversationId!);
    }
    activeConversationId = conversationId;
  }

  Future<void> markConversationRead(String conversationId) async {
    final msgs = visibleMessagesFor(conversationId);
    final markAt = msgs.isNotEmpty ? msgs.last.createdAt : DateTime.now();
    await _chatPrefs.setLastRead(conversationId, markAt);
    unreadCounts[conversationId] = 0;
    await _sendReadReceipt(conversationId, markAt);
    notifyListeners();
  }

  Future<void> _sendReadReceipt(String conversationId, DateTime readUntil) async {
    if (session == null) return;
    if (!await SettingsRuntime.instance.readReceiptsEnabled()) return;
    Conversation? conv;
    for (final c in conversations) {
      if (c.id == conversationId) {
        conv = c;
        break;
      }
    }
    if (conv == null || conv.isGroup) return;
    final peer = directPeerUserId(conv);
    if (peer == null || !isConversationReachable(conv)) return;
    try {
      final payload = jsonEncode({
        'conversation_id': conversationId,
        'read_until': readUntil.toIso8601String(),
      });
      await _ensureSessionWith(peer);
      final ciphertext = await crypto!.encrypt(peer, Uint8List.fromList(utf8.encode(payload)));
      final directConv = await _findOrCreateDirectConversation(peer);
      await _api.sendMessage(
        conversationId: directConv.id,
        ciphertext: ciphertext,
        contentType: 'read_receipt',
      );
    } catch (e) {
      DebugLog.instance.error('delivery', 'read_receipt send failed: $e');
    }
  }

  Future<void> _handleReadReceipt(ChatMessage msg) async {
    if (!await SettingsRuntime.instance.readReceiptsVisible()) return;
    if (msg.plaintext == null) await _decryptInPlace(msg);
    if (msg.plaintext == null) return;
    try {
      final data = jsonDecode(msg.plaintext!) as Map<String, dynamic>;
      final convId = data['conversation_id'] as String?;
      final untilRaw = data['read_until'] as String?;
      if (convId == null || untilRaw == null) return;
      final until = DateTime.parse(untilRaw);
      await MessageDeliveryStore.instance.setPeerReadUntil(convId, until);
      notifyListeners();
    } catch (e) {
      DebugLog.instance.error('delivery', 'read_receipt parse failed: $e');
    }
  }

  Future<void> recomputeUnread(String conversationId) async {
    final lastRead = await _chatPrefs.getLastRead(conversationId);
    final msgs = visibleMessagesFor(conversationId);
    unreadCounts[conversationId] = msgs.where((m) {
      if (m.senderUserId == session?.userId) return false;
      if (lastRead == null) return true;
      return m.createdAt.isAfter(lastRead);
    }).length;
  }

  Future<void> recomputeAllUnread() async {
    for (final c in conversations) {
      await recomputeUnread(c.id);
    }
  }

  bool _isNonChatEnvelope(ChatMessage m) {
    if (m.contentType == 'read_receipt' ||
        m.contentType == 'login_approval_grant' ||
        m.contentType == 'sender_key_distribution') {
      return true;
    }
    return CallSignalingService.isCallSignal(m.contentType);
  }

  Future<void> _processHistoryControlMessage(ChatMessage m) async {
    if (m.contentType == 'read_receipt') {
      await _handleReadReceipt(m);
    } else if (m.contentType == 'login_approval_grant') {
      await _handleLoginApprovalSignal(m);
    } else if (m.contentType == 'sender_key_distribution') {
      await _processIncomingDistribution(m);
    } else if (CallSignalingService.isCallSignal(m.contentType)) {
      await _handleIncomingCallSignal(m);
    }
  }

  List<ChatMessage> visibleMessagesFor(String conversationId) {
    final all = messagesByConversation[conversationId] ?? [];
    final secretOn = isSecretSessionActive(conversationId);
    var visible = all.where((m) => !_locallyHiddenMessageIds.contains(m.id) && !_isNonChatEnvelope(m));
    if (!secretOn) {
      visible = visible.where((m) => !m.isSecret);
    }
    final normalSeconds = disappearingSeconds[conversationId];
    if (normalSeconds != null) {
      final cutoff = DateTime.now().subtract(Duration(seconds: normalSeconds));
      visible = visible.where((m) => m.isSecret || m.createdAt.isAfter(cutoff));
    }
    final secretSeconds = secretDisappearingSeconds;
    if (secretSeconds != null) {
      final cutoff = DateTime.now().subtract(Duration(seconds: secretSeconds));
      visible = visible.where((m) => !m.isSecret || m.createdAt.isAfter(cutoff));
    }
    // Per-message TTL from outgoing auto-delete envelope.
    final now = DateTime.now();
    visible = visible.where((m) {
      final ttl = m.ttlSeconds;
      if (ttl == null || ttl <= 0) return true;
      return m.createdAt.add(Duration(seconds: ttl)).isAfter(now);
    });
    return visible.toList();
  }

  List<ChatMessage> searchMessages(String conversationId, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    return visibleMessagesFor(conversationId).where((m) {
      if (m.decryptFailed || m.plaintext == null) return false;
      if (m.contentType == 'text') return m.plaintext!.toLowerCase().contains(q);
      if (m.contentType == 'image') return 'фото'.contains(q) || q.contains('photo');
      return false;
    }).toList();
  }

  List<ChatMessage> imageMessagesFor(String conversationId) {
    return visibleMessagesFor(conversationId).where((m) => m.contentType == 'image' && !m.decryptFailed).toList();
  }

  Future<void> clearLocalHistory(String conversationId) async {
    messagesByConversation.remove(conversationId);
    final userId = session?.userId;
    if (userId != null) {
      await _messageCache.clearConversation(userId, conversationId);
    }
    await markConversationRead(conversationId);
    notifyListeners();
  }

  Future<void> setChatMuted(String conversationId, bool muted) async {
    await _chatPrefs.setMuted(conversationId, muted);
    chatMuted[conversationId] = muted;
    notifyListeners();
  }

  Future<void> setDisappearingSeconds(String conversationId, int? seconds) async {
    await _chatPrefs.setDisappearingSeconds(conversationId, seconds);
    disappearingSeconds[conversationId] = seconds;
    notifyListeners();
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

  String labelFor(String userId) {
    if (userId == session?.userId) return 'Вы';
    final cached = knownDisplayNames[userId];
    if (cached != null) return cached;
    final prefixLen = userId.length < 8 ? userId.length : 8;
    return '${userId.substring(0, prefixLen)}…';
  }

  Conversation? conversationLabelSource(Conversation c) => c;

  String conversationTitle(Conversation c) {
    if (FavoritesChat.isId(c.id)) return 'Избранное';
    if (c.name != null && c.name!.isNotEmpty) return c.name!;
    final others = c.participantUserIds.where((id) => id != session?.userId);
    return others.map(labelFor).join(', ');
  }

  String? directPeerUserId(Conversation conversation) {
    if (conversation.isGroup || session == null) return null;
    for (final id in conversation.participantUserIds) {
      if (id != session!.userId) return id;
    }
    return null;
  }

  Conversation? findDirectConversationWith(String peerUserId) {
    final me = session?.userId;
    if (me == null) return null;
    for (final c in conversations) {
      if (c.isGroup) continue;
      final peers = c.participantUserIds.toSet();
      if (peers.length == 2 && peers.contains(me) && peers.contains(peerUserId)) return c;
    }
    return null;
  }

  Future<void> validateConversationReachability(Conversation conversation) async {
    if (conversation.isGroup) {
      conversationReachable[conversation.id] = true;
      conversationReachabilityError[conversation.id] = null;
      return;
    }
    final peer = directPeerUserId(conversation);
    if (peer == null) {
      conversationReachable[conversation.id] = false;
      conversationReachabilityError[conversation.id] = 'Нет собеседника в чате';
      return;
    }
    if (!isValidUserIdFormat(peer)) {
      conversationReachable[conversation.id] = false;
      conversationReachabilityError[conversation.id] = 'Некорректный User ID собеседника: $peer';
      DebugLog.instance.error('chat', 'invalid peer id format', peer);
      return;
    }
    try {
      DebugLog.instance.info('prekey', 'GET /users/$peer/prekey-bundle');
      await _api.getPreKeyBundle(peer);
      conversationReachable[conversation.id] = true;
      conversationReachabilityError[conversation.id] = null;
      DebugLog.instance.info('prekey', 'OK for $peer');
    } on ApiException catch (e) {
      conversationReachable[conversation.id] = false;
      conversationReachabilityError[conversation.id] =
          'Собеседник $peer не найден на сервере (${e.statusCode}: ${e.message})';
      DebugLog.instance.error('prekey', 'failed for $peer', e);
    } catch (e) {
      conversationReachable[conversation.id] = false;
      conversationReachabilityError[conversation.id] = 'Ошибка проверки $peer: $e';
      DebugLog.instance.error('prekey', 'failed for $peer', e);
    }
    notifyListeners();
  }

  Future<void> validateAllConversationsReachability() async {
    for (final c in conversations) {
      await validateConversationReachability(c);
    }
  }

  bool isConversationReachable(Conversation conversation) {
    if (FavoritesChat.isId(conversation.id)) return true;
    if (conversation.isGroup) return true;
    return conversationReachable[conversation.id] ?? true;
  }

  String? reachabilityErrorFor(Conversation conversation) =>
      conversationReachabilityError[conversation.id];

  Future<String> verifyPeerUserId(String rawUserId) async {
    final id = normalizeUserId(rawUserId);
    if (!isValidUserIdFormat(id)) {
      throw ArgumentError(userIdFormatHint());
    }
    if (id == session?.userId) {
      throw ArgumentError('Нельзя начать чат с самим собой');
    }
    try {
      await _api.getPreKeyBundle(id);
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        throw ArgumentError(
          'Пользователь $id не найден на сервере. '
          'Собеседник должен зарегистрироваться, затем скопировать User ID из Настройки → Аккаунт.',
        );
      }
      rethrow;
    }
    return id;
  }

  Future<Conversation> startDirectChat(String otherUserId, String otherDisplayName) async {
    final id = await verifyPeerUserId(otherUserId);
    knownDisplayNames[id] = otherDisplayName.trim().isEmpty ? labelFor(id) : otherDisplayName.trim();
    if (!contactTrustLevels.containsKey(id)) {
      await setContactTrustLevel(id, TrustLevel.normal, logEvent: false);
    }

    final existing = findDirectConversationWith(id);
    if (existing != null) {
      DebugLog.instance.info('chat', 'reuse existing direct conversation ${existing.id} with $id');
      await validateConversationReachability(existing);
      return existing;
    }

    DebugLog.instance.info('chat', 'create direct conversation with $id');
    final json = await _api.createConversation(type: 'direct', participantUserIds: [id]);
    final conv = Conversation.fromJson(json);
    await refreshConversations();
    await validateConversationReachability(conv);
    return conv;
  }

  Future<Conversation> startGroupChat(String name, List<MapEntry<String, String>> members) async {
    final resolved = <MapEntry<String, String>>[];
    for (final m in members) {
      final id = await verifyPeerUserId(m.key);
      final label = m.value.trim().isEmpty ? labelFor(id) : m.value.trim();
      resolved.add(MapEntry(id, label));
      knownDisplayNames[id] = label;
    }
    final json = await _api.createConversation(
      type: 'group',
      name: name,
      participantUserIds: resolved.map((m) => m.key).toList(),
    );
    final conv = Conversation.fromJson(json);
    _locallyCreatedGroupIds.add(conv.id);
    await refreshConversations();
    return conv;
  }

  Future<void> loadHistory(String conversationId) async {
    if (FavoritesChat.isId(conversationId)) {
      await _syncFavoritesChat();
      notifyListeners();
      return;
    }
    final userId = session?.userId;
    final prior = List<ChatMessage>.from(messagesByConversation[conversationId] ?? []);
    List<ChatMessage> diskCached = [];
    if (userId != null) {
      diskCached = await _messageCache.loadConversation(userId, conversationId);
      if (diskCached.isNotEmpty && prior.isEmpty) {
        for (final m in diskCached) {
          MessagePayload.applyTo(m);
          _sealSecretMessage(m);
        }
        messagesByConversation[conversationId] = diskCached;
        prior.addAll(diskCached);
        await recomputeUnread(conversationId);
        notifyListeners();
      }
    }

    final plaintextIndex = _plaintextIndexFor(conversationId, [...diskCached, ...prior]);

    final runtime = SettingsRuntime.instance;
    if (!await runtime.messageHistorySyncAllowed()) {
      await recomputeUnread(conversationId);
      notifyListeners();
      return;
    }
    final maxAge = await runtime.historySyncMaxAge();
    if (maxAge == Duration.zero) {
      await recomputeUnread(conversationId);
      notifyListeners();
      return;
    }

    final raw = await _api.getMessages(conversationId, limit: 100);
    var all = raw.map((j) => ChatMessage.fromJson(j as Map<String, dynamic>)).toList();
    if (maxAge != null) {
      final cutoff = DateTime.now().subtract(maxAge);
      all = all.where((m) => !m.createdAt.isBefore(cutoff)).toList();
    }
    all.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final mergedById = <String, ChatMessage>{
      for (final m in prior) m.id: m,
    };

    for (final m in all) {
      if (_isNonChatEnvelope(m)) {
        await _processHistoryControlMessage(m);
        continue;
      }

      final indexed = plaintextIndex[m.id];
      if (indexed != null) {
        _applyPlaintextFrom(m, indexed);
      } else {
        await _decryptInPlace(m, plaintextIndex: plaintextIndex);
      }

      final existing = mergedById[m.id];
      if (existing != null &&
          existing.plaintext != null &&
          existing.plaintext!.isNotEmpty &&
          !existing.decryptFailed &&
          (m.plaintext == null || m.plaintext!.isEmpty || m.decryptFailed)) {
        _applyPlaintextFrom(m, existing);
      }
      mergedById[m.id] = m;
    }

    final merged = mergedById.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    messagesByConversation[conversationId] = merged;
    if (userId != null) {
      try {
        // Never persist decrypt-failed shells — that used to overwrite good local plaintext
        // after a device-key rotation and made history permanently unreadable.
        final persistable = merged
            .where((m) => m.plaintext != null && m.plaintext!.isNotEmpty && !m.decryptFailed)
            .toList();
        if (persistable.isNotEmpty) {
          await _messageCache.upsertMessages(userId, persistable);
        }
      } catch (e) {
        debugPrint('Message cache bulk persist failed: $e');
      }
    }
    await recomputeUnread(conversationId);
    notifyListeners();
  }

  /// If we already have a pending/outgoing bubble, replace it instead of duplicating.
  bool _absorbOutgoingEcho(List<ChatMessage> list, ChatMessage incoming) {
    final me = session?.userId;
    if (me == null || incoming.senderUserId != me) return false;

    final pendingIdx = list.indexWhere((m) =>
        m.senderUserId == me &&
        m.cryptoVersion == 'local-pending' &&
        m.contentType == incoming.contentType &&
        m.createdAt.difference(incoming.createdAt).inSeconds.abs() < 120);
    if (pendingIdx >= 0) {
      final pending = list[pendingIdx];
      incoming.plaintext ??= pending.plaintext;
      incoming.replyToMessageId ??= pending.replyToMessageId;
      incoming.replyPreview ??= pending.replyPreview;
      list[pendingIdx] = incoming;
      return true;
    }

    final dupIdx = list.indexWhere((m) =>
        m.id != incoming.id &&
        m.senderUserId == me &&
        m.contentType == incoming.contentType &&
        m.ciphertext == incoming.ciphertext);
    if (dupIdx >= 0) {
      list[dupIdx] = incoming;
      return true;
    }
    return false;
  }

  Future<void> _persistMessage(ChatMessage message) async {
    final userId = session?.userId;
    if (userId == null) return;
    try {
      await _messageCache.upsertMessage(userId, message);
    } catch (e) {
      debugPrint('Message cache persist failed: $e');
    }
  }

  Future<void> _ensureSessionWith(String otherUserId) async {
    if (await crypto!.hasSessionWith(otherUserId)) return;
    DebugLog.instance.info('crypto', 'establish session with $otherUserId');
    final bundleResp = await _api.getPreKeyBundle(otherUserId);
    try {
      await crypto!.establishSessionFromBundle(otherUserId, bundleResp['bundle'] as Map<String, dynamic>);
    } catch (e) {
      if (_isUntrustedIdentityError(e)) {
        await _handleIdentityKeyChange(otherUserId);
      }
      rethrow;
    }
  }

  bool _isUntrustedIdentityError(Object e) {
    final s = e.toString();
    return s.contains('UntrustedIdentityException') || s.contains('Untrusted identity');
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

  String _cryptoQueueKey(ChatMessage m, {Conversation? conversation}) {
    final conv = conversation ?? _findConversation(m.conversationId);
    if (conv?.isGroup == true) {
      return 'group:${m.conversationId}:${m.senderUserId}';
    }
    return 'direct:${m.senderUserId}';
  }

  Map<String, ChatMessage> _plaintextIndexFor(String conversationId, List<ChatMessage> diskCached) {
    final index = <String, ChatMessage>{};
    for (final m in diskCached) {
      if (m.plaintext != null && m.plaintext!.isNotEmpty && !m.decryptFailed) {
        index[m.id] = m;
      }
    }
    for (final m in messagesByConversation[conversationId] ?? []) {
      if (m.plaintext != null && m.plaintext!.isNotEmpty && !m.decryptFailed) {
        index[m.id] = m;
      }
    }
    return index;
  }

  void _applyPlaintextFrom(ChatMessage target, ChatMessage source) {
    if (source.plaintext == null || source.plaintext!.isEmpty) return;
    target.plaintext = source.plaintext;
    target.replyToMessageId = source.replyToMessageId;
    target.replyPreview = source.replyPreview;
    target.decryptFailed = false;
    MessagePayload.applyTo(target);
  }

  bool _isDuplicateDecryptError(Object e) =>
      e.toString().contains('DuplicateMessageException');

  Future<void> _decryptInPlace(ChatMessage m, {Map<String, ChatMessage>? plaintextIndex}) async {
    // Reuse plaintext from disk/memory index — Signal keys are single-use.
    final indexed = plaintextIndex?[m.id];
    if (indexed != null) {
      _applyPlaintextFrom(m, indexed);
      if (m.plaintext != null) return;
    }

    // Reuse a previous successful decryption for this message id in memory.
    final cached = messagesByConversation[m.conversationId]
        ?.where((existing) => existing.id == m.id)
        .toList();
    if (cached != null && cached.isNotEmpty) {
      final existing = cached.first;
      if (existing.plaintext != null && existing.plaintext!.isNotEmpty && !existing.decryptFailed) {
        _applyPlaintextFrom(m, existing);
        return;
      }
    }

    // Outgoing messages cannot be Signal-decrypted on this device — plaintext from cache only.
    if (m.senderUserId == session?.userId) {
      return;
    }

    final conversation = _findConversation(m.conversationId);
    final queueKey = _cryptoQueueKey(m, conversation: conversation);
    await _cryptoDecryptQueue.run(queueKey, () async {
      if (m.plaintext != null) return;
      try {
        final plaintextBytes = conversation?.isGroup == true
            ? await crypto!.decryptGroup(m.conversationId, m.senderUserId, m.ciphertext)
            : await crypto!.decrypt(m.senderUserId, m.ciphertext);
        m.plaintext = utf8.decode(plaintextBytes);
        m.decryptFailed = false;
        MessagePayload.applyTo(m);
        _sealSecretMessage(m);
      } catch (e) {
        if (_isUntrustedIdentityError(e)) {
          await _handleIdentityKeyChange(m.senderUserId);
        }
        if (_isDuplicateDecryptError(e)) {
          final fromIndex = plaintextIndex?[m.id];
          if (fromIndex != null) {
            _applyPlaintextFrom(m, fromIndex);
            if (m.plaintext != null) return;
          }
          final inMemory = messagesByConversation[m.conversationId]
              ?.where((existing) => existing.id == m.id)
              .firstOrNull;
          if (inMemory?.plaintext != null && inMemory!.plaintext!.isNotEmpty) {
            _applyPlaintextFrom(m, inMemory);
            if (m.plaintext != null) return;
          }
        }
        m.decryptFailed = true;
        DebugLog.instance.error('crypto', 'decrypt failed msg=${m.id.substring(0, 8)}… sender=${m.senderUserId}: $e');
      }
    });
  }

  /// Distributes my sender key for this group to every other member, once
  /// per session, via their existing 1:1 pairwise session — see
  /// 0301_GROUP_MESSAGING.md → Распространение sender key. Idempotent
  /// per-group thanks to `_groupKeysDistributed`.
  Future<void> _distributeGroupKeyIfNeeded(Conversation conversation) async {
    if (_groupKeysDistributed.contains(conversation.id)) return;

    final distributionB64 = await crypto!.createGroupSenderKeyDistribution(conversation.id, session!.userId);
    final payload = jsonEncode({'group_id': conversation.id, 'distribution': distributionB64});

    for (final memberId in conversation.participantUserIds) {
      if (memberId == session!.userId) continue;
      await _ensureSessionWith(memberId);
      final ciphertext = await crypto!.encrypt(memberId, Uint8List.fromList(utf8.encode(payload)));
      final directConv = await _findOrCreateDirectConversation(memberId);
      await _api.sendMessage(
        conversationId: directConv.id,
        ciphertext: ciphertext,
        contentType: 'sender_key_distribution',
      );
    }

    _groupKeysDistributed.add(conversation.id);
  }

  /// Adds members to a group conversation and distributes the sender key to new members.
  Future<void> addGroupMembers(Conversation conversation, List<String> userIds) async {
    if (crypto == null || session == null) return;
    final updatedJson = await _api.addGroupMembers(conversation.id, userIds);
    final updated = Conversation.fromJson(updatedJson);

    // Update local state
    final idx = conversations.indexWhere((c) => c.id == conversation.id);
    if (idx >= 0) conversations[idx] = updated;

    // Send sender key distribution to new members
    final distributionB64 = await crypto!.createGroupSenderKeyDistribution(conversation.id, session!.userId);
    final payload = jsonEncode({'group_id': conversation.id, 'distribution': distributionB64});
    for (final memberId in userIds) {
      if (memberId == session!.userId) continue;
      try {
        await _ensureSessionWith(memberId);
        final ciphertext = await crypto!.encrypt(memberId, Uint8List.fromList(utf8.encode(payload)));
        final directConv = await _findOrCreateDirectConversation(memberId);
        await _api.sendMessage(
          conversationId: directConv.id,
          ciphertext: ciphertext,
          contentType: 'sender_key_distribution',
        );
      } catch (e) {
        DebugLog.instance.warn('group', 'Failed to distribute sender key to $memberId: $e');
      }
    }
    notifyListeners();
  }

  /// Removes a member from a group and rotates the sender key (forward secrecy).
  Future<void> removeGroupMember(Conversation conversation, String userId) async {
    if (crypto == null || session == null) return;
    await _api.removeGroupMember(conversation.id, userId);

    // Rotate sender key — invalidate current key so removed member can't decrypt future messages
    _groupKeysDistributed.remove(conversation.id);

    // Update local conversation state
    final idx = conversations.indexWhere((c) => c.id == conversation.id);
    if (idx >= 0) {
      // Refresh from server to get accurate participant list
      await refreshConversations();
      final refreshed = conversations.firstWhere((c) => c.id == conversation.id, orElse: () => conversation);

      // Distribute new sender key to remaining members
      await _distributeGroupKeyIfNeeded(refreshed);
    }
    notifyListeners();
  }

  /// Reuses an existing direct Conversation with [otherUserId] if we
  /// already have one locally, to avoid piling up duplicate 1:1
  /// conversations purely for control-message delivery.
  Future<Conversation> _findOrCreateDirectConversation(String otherUserId) async {
    for (final c in conversations) {
      if (!c.isGroup && c.participantUserIds.contains(otherUserId) && c.participantUserIds.length == 2) {
        return c;
      }
    }
    final json = await _api.createConversation(type: 'direct', participantUserIds: [otherUserId]);
    final conv = Conversation.fromJson(json);
    conversations.add(conv);
    return conv;
  }

  Future<void> _sendCallSignal({required String peerUserId, required String contentType, required String ciphertext}) async {
    final conv = await _findOrCreateDirectConversation(peerUserId);
    await _api.sendMessage(conversationId: conv.id, ciphertext: ciphertext, contentType: contentType);
  }

  /// Reference public STUN plus, if reachable, one Turn Node's temporary
  /// credentials (spec/0605_TURN_NODE.md, spec/0303_CALLS.md). Never throws
  /// — no Turn Node available just means STUN-only (P2P-capable networks
  /// still work; NAT/firewall-blocked ones won't, a known degraded mode).
  Future<List<Map<String, dynamic>>> _resolveIceServers() async {
    final servers = <Map<String, dynamic>>[
      {'urls': 'stun:stun.l.google.com:19302'},
    ];
    final allowRelays = await SettingsRuntime.instance.nodeAllowRelays();
    if (!allowRelays) {
      DebugLog.instance.info('calls', 'node.allow_relays=false — STUN only');
      return servers;
    }
    try {
      final nodes = await _api.findNodes(capability: 'turn');
      final online = nodes.map((n) => n as Map<String, dynamic>).where((n) => n['status'] == 'online');
      if (online.isNotEmpty) {
        final creds = await _api.fetchTurnCredentials(online.first['node_url'] as String);
        final uris = (creds['uris'] as List).cast<String>().where(_isUsableTurnUri).toList();
        if (uris.isNotEmpty) {
          servers.add({
            'urls': uris,
            'username': creds['username'],
            'credential': creds['password'],
          });
        } else {
          DebugLog.instance.warn(
            'calls',
            'TURN URIs unusable (localhost?) — set TURN_SERVER_HOST on worker + run coturn :3478',
          );
        }
      }
    } catch (e) {
      DebugLog.instance.warn('calls', 'TURN discovery failed: $e');
    }
    return servers;
  }

  bool _isUsableTurnUri(String uri) {
    if (uri.contains('localhost') || uri.contains('127.0.0.1')) return false;
    return true;
  }

  /// Starts an outgoing call to [peerUserId]: creates our WebRTC connection
  /// and offer, sends `call_offer` over the existing 1:1 E2EE session, and
  /// tracks it as [currentCall] (spec/0303_CALLS.md, ADR-0008).
  Future<void> startCall({required String peerUserId, required CallKind kind}) async {
    if (currentCall != null) throw StateError('already in a call');
    final runtime = SettingsRuntime.instance;
    var effectiveKind = kind;
    if (kind == CallKind.video && !await runtime.callsVideo()) {
      effectiveKind = CallKind.audio;
    }
    final callId = _uuid.v4();
    await _ensureSessionWith(peerUserId);

    final media = await CallMediaController.create(
      iceServers: await _resolveIceServers(),
      video: effectiveKind == CallKind.video,
      forceRelay: await runtime.callsIceRelayOnly(),
      noiseSuppression: await runtime.callsNoiseSuppression(),
      echoCancellation: await runtime.callsEchoCancellation(),
      quality: await runtime.callsQuality(),
      dataSaver: await runtime.callsDataSaver(),
    );
    final call = ActiveCall(callId: callId, peerUserId: peerUserId, kind: effectiveKind, outgoing: true)..media = media;
    currentCall = call;
    callUiMinimized = false;
    _wireMedia(call, media);
    notifyListeners();

    final sdp = await media.createOffer();
    await _sendCallSignal(
      peerUserId: peerUserId,
      contentType: CallSignalType.offer.contentType,
      ciphertext: await _callSignaling.encodeOffer(peerUserId: peerUserId, callId: callId, kind: effectiveKind, sdp: sdp),
    );
  }

  /// Answers the currently ringing incoming call: creates our WebRTC
  /// connection from the peer's offer (already stored as `remoteSdp`) and
  /// sends back `call_answer`.
  Future<void> answerCall() async {
    final call = currentCall;
    if (call == null || call.outgoing || call.answered || call.remoteSdp == null) return;

    final runtime = SettingsRuntime.instance;
    final useVideo = call.kind == CallKind.video && await runtime.callsVideo();

    final media = await CallMediaController.create(
      iceServers: await _resolveIceServers(),
      video: useVideo,
      forceRelay: await runtime.callsIceRelayOnly(),
      noiseSuppression: await runtime.callsNoiseSuppression(),
      echoCancellation: await runtime.callsEchoCancellation(),
      quality: await runtime.callsQuality(),
      dataSaver: await runtime.callsDataSaver(),
    );
    call.media = media;
    _wireMedia(call, media);
    for (final candidate in call.pendingRemoteIceCandidates) {
      await media.addRemoteIceCandidate(candidate);
    }
    call.pendingRemoteIceCandidates.clear();

    final sdp = await media.createAnswer(call.remoteSdp!);
    await _sendCallSignal(
      peerUserId: call.peerUserId,
      contentType: CallSignalType.answer.contentType,
      ciphertext: await _callSignaling.encodeAnswer(peerUserId: call.peerUserId, callId: call.callId, sdp: sdp),
    );
    call.answered = true;
    call.answeredAt = DateTime.now();
    notifyListeners();
  }

  /// Opens an existing 1:1 chat or creates one using the locally known name.
  Conversation? findDirectConversation(String otherUserId) {
    for (final c in conversations) {
      if (!c.isGroup && c.participantUserIds.contains(otherUserId) && c.participantUserIds.length == 2) {
        return c;
      }
    }
    return null;
  }

  Future<Conversation> openOrCreateDirectChat(String otherUserId) async {
    final existing = findDirectConversation(otherUserId);
    if (existing != null) return existing;
    final name = knownDisplayNames[otherUserId] ?? labelFor(otherUserId);
    return startDirectChat(otherUserId, name);
  }

  Future<void> setContactAlias(String userId, String name) async {
    await _contactStore.setAlias(userId, name);
    _contactAliases[userId] = name;
    knownDisplayNames[userId] = name;
    notifyListeners();
  }

  TrustLevel trustLevelFor(String userId) => contactTrustLevels[userId] ?? TrustLevel.unknown;

  Future<void> setContactTrustLevel(String userId, TrustLevel level, {bool logEvent = true}) async {
    await _contactTrustStore.setTrust(userId, level);
    contactTrustLevels[userId] = level;
    if (logEvent) {
      await SecurityLogService.instance.append(
        SecurityEvent(
          title: 'Уровень доверия изменён',
          subtitle: '${labelFor(userId)} → ${level.label}',
          at: DateTime.now(),
          icon: 'shield',
        ),
      );
    }
    if (level.index >= TrustLevel.trusted.index) {
      await SecurityMetaStore.instance.recordContactVerification();
    }
    notifyListeners();
  }

  DateTime? lastActivityFor(String userId) {
    DateTime? latest;
    for (final msgs in messagesByConversation.values) {
      for (final m in msgs) {
        if (m.senderUserId == userId) {
          if (latest == null || m.createdAt.isAfter(latest)) latest = m.createdAt;
        }
      }
    }
    for (final call in callHistory) {
      if (call.peerUserId == userId) {
        if (latest == null || call.startedAt.isAfter(latest)) latest = call.startedAt;
      }
    }
    return latest;
  }

  bool isContactOnline(String userId) {
    if (!canShowOnlineStatusFor(userId)) return false;
    if (currentCall?.peerUserId == userId && currentCall!.answered) return true;
    final last = lastActivityFor(userId);
    if (last == null) return false;
    return DateTime.now().difference(last.toLocal()).inMinutes < 5;
  }

  String contactStatusLabel(String userId) {
    if (currentCall?.peerUserId == userId) {
      return currentCall!.answered ? 'В звонке' : 'Звонит…';
    }
    if (isContactOnline(userId)) return 'Недавно в сети';
    if (!canShowLastSeenFor(userId)) return '';
    final last = lastActivityFor(userId);
    if (last == null) return 'Не в сети';
    return formatRelativeTime(last);
  }

  Future<void> callPeer({required String peerUserId, required CallKind kind}) async {
    await startCall(peerUserId: peerUserId, kind: kind);
  }

  Future<void> clearCallHistory() async {
    await _callHistoryStore.clear();
    callHistory = [];
    notifyListeners();
  }

  /// Wires one call's WebRTC events to signaling delivery and to the
  /// network-resilience handling in spec/0303_CALLS.md → Устойчивость
  /// соединения (disconnected ≠ hang up).
  void _wireMedia(ActiveCall call, CallMediaController media) {
    media.onLocalIceCandidate = (candidate) => unawaited(_sendLocalIceCandidate(call, candidate));
    media.connectionState.listen((state) => unawaited(_onMediaConnectionState(call, state)));
  }

  Future<void> _sendLocalIceCandidate(ActiveCall call, Map<String, dynamic> candidate) async {
    if (currentCall?.callId != call.callId) return; // call already ended
    try {
      await _sendCallSignal(
        peerUserId: call.peerUserId,
        contentType: CallSignalType.iceCandidate.contentType,
        ciphertext: await _callSignaling.encodeIceCandidate(peerUserId: call.peerUserId, callId: call.callId, candidate: candidate),
      );
    } catch (_) {
      // Losing one candidate isn't fatal — ICE just tries the others.
    }
  }

  static const _networkRecoveryTimeout = Duration(seconds: 20);

  Future<void> _onMediaConnectionState(ActiveCall call, MediaConnectionState state) async {
    if (currentCall?.callId != call.callId) return;
    switch (state) {
      case MediaConnectionState.connected:
        if (!call.waitingForNetwork) return;
        call.waitingForNetwork = false;
        call.reconnectTimer?.cancel();
        notifyListeners();
      case MediaConnectionState.disconnected:
        if (call.waitingForNetwork) return; // already handling it
        call.waitingForNetwork = true;
        notifyListeners();
        unawaited(call.media?.restartIce());
        call.reconnectTimer = Timer(_networkRecoveryTimeout, () => unawaited(_onNetworkRecoveryTimedOut(call)));
      case MediaConnectionState.failed:
        call.reconnectTimer?.cancel();
        await _teardownAfterMediaFailure(call);
      case MediaConnectionState.connecting:
      case MediaConnectionState.closed:
        break;
    }
  }

  Future<void> _onNetworkRecoveryTimedOut(ActiveCall call) async {
    if (currentCall?.callId != call.callId || !call.waitingForNetwork) return; // recovered in the meantime
    await _teardownAfterMediaFailure(call);
  }

  /// A real, non-recoverable media failure — as opposed to `disconnected`,
  /// which never reaches this (spec/0303_CALLS.md → Устойчивость
  /// соединения). Best-effort notifies the peer, then tears down locally
  /// regardless of whether that notification succeeded.
  Future<void> _teardownAfterMediaFailure(ActiveCall call) async {
    if (currentCall?.callId != call.callId) return;
    final type = call.answered ? CallSignalType.end : (call.outgoing ? CallSignalType.cancel : CallSignalType.reject);
    try {
      await _sendTeardownSignal(call, type);
    } catch (_) {
      // best-effort — we're tearing down locally regardless
    }
    final status = call.answered
        ? CallHistoryStatus.completed
        : (call.outgoing ? CallHistoryStatus.cancelled : CallHistoryStatus.missed);
    await _finalizeCall(call, status);
    notifyListeners();
  }

  Future<void> _sendTeardownSignal(ActiveCall call, CallSignalType type) async {
    final ciphertext = switch (type) {
      CallSignalType.reject => await _callSignaling.encodeReject(peerUserId: call.peerUserId, callId: call.callId),
      CallSignalType.cancel => await _callSignaling.encodeCancel(peerUserId: call.peerUserId, callId: call.callId),
      CallSignalType.end => await _callSignaling.encodeEnd(peerUserId: call.peerUserId, callId: call.callId),
      _ => throw ArgumentError('not a teardown signal: $type'),
    };
    await _sendCallSignal(peerUserId: call.peerUserId, contentType: type.contentType, ciphertext: ciphertext);
  }

  Future<void> _finalizeCall(ActiveCall call, CallHistoryStatus status) async {
    int? duration;
    if (call.answeredAt != null && status == CallHistoryStatus.completed) {
      duration = DateTime.now().difference(call.answeredAt!).inSeconds;
      if (duration <= 0) duration = 1;
    }
    final entry = CallHistoryEntry(
      callId: call.callId,
      peerUserId: call.peerUserId,
      kind: call.kind,
      outgoing: call.outgoing,
      status: status,
      startedAt: call.startedAt,
      durationSeconds: duration,
    );
    final peerLabel = labelFor(call.peerUserId);
    await _callHistoryStore.append(entry);
    callHistory.insert(0, entry);
    if (callHistory.length > 200) {
      callHistory.removeRange(200, callHistory.length);
    }
    await _clearCall(call);
    _showCallEndedOverlay(peerLabel);
  }

  Future<void> _clearCall(ActiveCall call) async {
    call.reconnectTimer?.cancel();
    await call.media?.dispose();
    if (currentCall?.callId == call.callId) {
      currentCall = null;
      callUiMinimized = false;
    }
  }

  /// Declines the currently ringing incoming call.
  Future<void> rejectCall() async {
    final call = currentCall;
    if (call == null || call.outgoing || call.answered) return;
    await _sendTeardownSignal(call, CallSignalType.reject);
    await _finalizeCall(call, CallHistoryStatus.rejected);
    notifyListeners();
  }

  /// Cancels our own outgoing call before the peer has answered.
  Future<void> cancelCall() async {
    final call = currentCall;
    if (call == null || !call.outgoing || call.answered) return;
    await _sendTeardownSignal(call, CallSignalType.cancel);
    await _finalizeCall(call, CallHistoryStatus.cancelled);
    notifyListeners();
  }

  /// Ends the call currently in progress, once answered (either direction).
  Future<void> endCall() async {
    final call = currentCall;
    if (call == null || !call.answered) return;
    await _sendTeardownSignal(call, CallSignalType.end);
    await _finalizeCall(call, CallHistoryStatus.completed);
    notifyListeners();
  }

  Future<void> sendText(
    Conversation conversation,
    String text, {
    String? replyToMessageId,
    String? replyPreview,
  }) async {
    final peer = directPeerUserId(conversation);
    DebugLog.instance.info('send', 'text to conv=${conversation.id.substring(0, 8)}… peer=$peer');
    final clientMsgId = _uuid.v4();
    final secret = isSecretSessionActive(conversation.id) && !AppPrivacySession.instance.isInDecoyMode;
    final ttlSeconds = await SettingsRuntime.instance.outgoingAutoDeleteSeconds();
    final pending = ChatMessage(
      id: clientMsgId,
      conversationId: conversation.id,
      senderUserId: session!.userId,
      senderDeviceId: session!.deviceId,
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

    // If offline, enqueue for later and return without error.
    if (!websocketConnected) {
      await OutboxQueue.instance.enqueue(OutboxEntry(
        id: clientMsgId,
        conversationId: conversation.id,
        text: text,
        replyToMessageId: replyToMessageId,
        replyPreview: replyPreview,
        secret: secret,
        ttlSeconds: ttlSeconds,
      ));
      await MessageDeliveryStore.instance.setStatus(clientMsgId, MessageDeliveryStatus.queued);
      notifyListeners();
      return;
    }

    await MessageDeliveryStore.instance.setStatus(clientMsgId, MessageDeliveryStatus.sending);
    notifyListeners();

    try {
      final wireBody = MessagePayload.encodeText(
        body: text,
        secret: secret,
        replyToMessageId: replyToMessageId,
        replyPreview: replyPreview,
        ttlSeconds: ttlSeconds,
      );
      final ciphertext = await _encryptForConversation(conversation, Uint8List.fromList(utf8.encode(wireBody)));
      final resp = await _api.sendMessage(
        conversationId: conversation.id,
        ciphertext: ciphertext,
        contentType: 'text',
        clientMsgId: clientMsgId,
      );

      final msg = ChatMessage.fromJson(resp)
        ..plaintext = text
        ..replyToMessageId = replyToMessageId
        ..replyPreview = replyPreview
        ..isSecret = secret
        ..ttlSeconds = ttlSeconds;
      final list = messagesByConversation[conversation.id]!;
      final idx = list.indexWhere((m) => m.id == clientMsgId);
      if (idx >= 0) {
        list[idx] = msg;
      } else {
        list.add(msg);
      }
      await MessageDeliveryStore.instance.setStatus(msg.id, MessageDeliveryStatus.sent);
      await _persistMessage(msg);
      if (activeConversationId == conversation.id) {
        await markConversationRead(conversation.id);
      } else {
        await recomputeUnread(conversation.id);
      }
      _sortConversations();
      await refreshConversations();
      notifyListeners();
    } catch (e) {
      await MessageDeliveryStore.instance.setStatus(
        clientMsgId,
        MessageDeliveryStatus.failed,
        error: e.toString(),
      );
      notifyListeners();
      rethrow;
    }
  }

  /// Resend a locally failed outbound message (same plaintext, new server id).
  Future<void> retryFailedMessage(Conversation conversation, String messageId) async {
    final list = messagesByConversation[conversation.id];
    if (list == null) return;
    final idx = list.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    final msg = list[idx];
    final info = MessageDeliveryStore.instance.infoFor(messageId);
    if (info?.status != MessageDeliveryStatus.failed) return;
    final text = msg.plaintext;
    if (text == null || text.isEmpty) return;
    list.removeAt(idx);
    notifyListeners();
    await sendText(conversation, text);
  }

  Future<void> sendImage(Conversation conversation, Uint8List bytes, String filename, String mime) async {
    return sendAttachment(conversation, bytes, filename, mime, 'image');
  }

  Future<void> sendAttachment(
    Conversation conversation,
    Uint8List bytes,
    String filename,
    String mime,
    String contentType,
  ) async {
    final clientMsgId = _uuid.v4();
    final secret = isSecretSessionActive(conversation.id) && !AppPrivacySession.instance.isInDecoyMode;
    final ttlSeconds = await SettingsRuntime.instance.outgoingAutoDeleteSeconds();

    var payload = bytes;
    String? videoQualityHint;
    if (contentType == 'image') {
      payload = await MediaQuality.prepareImage(bytes);
    } else if (contentType == 'video') {
      final prepared = await MediaQuality.prepareVideo(bytes);
      payload = prepared.$1;
      videoQualityHint = prepared.$2;
    }

    final pending = ChatMessage(
      id: clientMsgId,
      conversationId: conversation.id,
      senderUserId: session!.userId,
      senderDeviceId: session!.deviceId,
      ciphertext: '',
      contentType: contentType,
      cryptoVersion: 'local-pending',
      createdAt: DateTime.now(),
      plaintext: '{"pending":true}',
      isSecret: secret,
      ttlSeconds: ttlSeconds,
    );
    messagesByConversation.putIfAbsent(conversation.id, () => []).add(pending);
    notifyListeners();

    try {
      final (cipherForUpload, pointer) = await MediaCrypto.encrypt(payload, filename: filename, mime: mime);
      final mediaId = await _uploadChatMedia(cipherForUpload, filename);
      final fullPointer = {
        ...pointer,
        'media_id': mediaId,
        if (videoQualityHint != null) 'video_quality': videoQualityHint,
      };
      final pointerJson = MessagePayload.encodeJsonMap(
        fullPointer,
        secret: secret,
        ttlSeconds: ttlSeconds,
      );

      final ciphertext =
          await _encryptForConversation(conversation, Uint8List.fromList(utf8.encode(pointerJson)));
      final resp = await _api.sendMessage(
        conversationId: conversation.id,
        ciphertext: ciphertext,
        contentType: contentType,
        clientMsgId: clientMsgId,
      );

      final msg = ChatMessage.fromJson(resp)
        ..plaintext = pointerJson
        ..ttlSeconds = ttlSeconds;
      MessagePayload.applyTo(msg);
      final list = messagesByConversation[conversation.id]!;
      final idx = list.indexWhere((m) => m.id == clientMsgId);
      if (idx >= 0) {
        list[idx] = msg;
      } else {
        list.add(msg);
      }
      if (!await SettingsRuntime.instance.shouldIsolateHiddenMedia(
        isSecretHidden: isSecretHidden(conversation.id),
      )) {
        MediaCache.instance.put(mediaId, payload);
        await GallerySaveService.instance.maybeSave(filename: filename, bytes: payload);
      }
      await _persistMessage(msg);
      if (activeConversationId == conversation.id) {
        await markConversationRead(conversation.id);
      } else {
        await recomputeUnread(conversation.id);
      }
      _sortConversations();
      await refreshConversations();
      notifyListeners();
    } catch (e) {
      final list = messagesByConversation[conversation.id];
      list?.removeWhere((m) => m.id == clientMsgId);
      notifyListeners();
      rethrow;
    }
  }

  /// Group → sender-key encryption (0301_GROUP_MESSAGING.md), distributing
  /// the key first if needed. Direct → existing pairwise Double Ratchet.
  Future<String> _encryptForConversation(Conversation conversation, Uint8List plaintext) async {
    if (conversation.isGroup) {
      await _distributeGroupKeyIfNeeded(conversation);
      return crypto!.encryptGroup(conversation.id, session!.userId, plaintext);
    }
    final other = directPeerUserId(conversation);
    if (other == null) {
      throw StateError('В чате нет собеседника');
    }
    if (!isConversationReachable(conversation)) {
      final detail = reachabilityErrorFor(conversation) ?? 'Собеседник $other не найден';
      DebugLog.instance.error('send', detail);
      throw StateError(detail);
    }
    await _ensureSessionWith(other);
    return crypto!.encrypt(other, plaintext);
  }

  void _configurePpcMediaStore() {
    final userId = session?.userId;
    final keys = authKeyPair;
    if (userId == null || keys == null) return;
    PersonalPcMediaStore.instance.configure(userId: userId, authKeyPair: keys);
  }

  Future<String> _uploadChatMedia(Uint8List ciphertext, String filename) async {
    _configurePpcMediaStore();
    if (await PersonalPcMediaStore.instance.shouldHandleMedia()) {
      return PersonalPcMediaStore.instance.upload(ciphertext);
    }
    return _api.uploadMedia(ciphertext, filename);
  }

  Future<Uint8List> _downloadChatMedia(String mediaId) async {
    if (mediaId.startsWith(PersonalPcMediaStore.mediaIdPrefix)) {
      _configurePpcMediaStore();
      return PersonalPcMediaStore.instance.download(mediaId);
    }
    return _api.downloadMedia(mediaId);
  }

  Future<Uint8List> resolveImageBytes(ChatMessage message, {bool forceDownload = false}) async {
    return resolveAttachmentBytes(message, forceDownload: forceDownload);
  }

  Future<Uint8List> resolveAttachmentBytes(ChatMessage message, {bool forceDownload = false}) async {
    if (message.plaintext == null || message.plaintext!.isEmpty) {
      throw StateError('attachment metadata missing');
    }
    final pointer = jsonDecode(message.plaintext!) as Map<String, dynamic>;
    if (pointer['pending'] == true) {
      throw StateError('attachment still uploading');
    }
    final mediaId = pointer['media_id'] as String?;
    if (mediaId == null || mediaId.isEmpty) {
      throw StateError('media_id missing');
    }
    final cached = MediaCache.instance.get(mediaId);
    if (cached != null) return cached;
    if (!forceDownload) {
      throw StateError('autodownload_disabled');
    }
    final cipherBytes = await _downloadChatMedia(mediaId);
    final plain = await MediaCrypto.decrypt(cipherBytes, pointer);
    if (!await SettingsRuntime.instance.shouldIsolateHiddenMedia(
      isSecretHidden: isSecretHidden(message.conversationId),
    )) {
      MediaCache.instance.put(mediaId, plain);
      final name = pointer['filename'] as String? ?? mediaId;
      await GallerySaveService.instance.maybeSave(filename: name, bytes: plain);
    }
    return plain;
  }

  Future<void> loadMyProfile() async {
    final me = await _api.getMyProfile();
    phone = me['phone'] as String?;
    login = me['login'] as String?;
    email = me['email'] as String?;
    notifyListeners();
  }

  Future<void> refreshDevices() async {
    devices = await _api.listMyDevices();
    await _syncDeviceTrustProfiles();
    await _loadDeviceSessionMeta();
    await _recordCurrentDeviceSessionMeta();
    await _scanPendingLoginApprovals();
    await LoginApprovalService.instance.pruneDismissed(devices.map((d) => d.id));
    notifyListeners();
  }

  Future<void> _loadDeviceSessionMeta() async {
    deviceSessionMeta.clear();
    for (final d in devices) {
      final meta = await DeviceSessionMetaStore.instance.get(d.id);
      if (meta != null) deviceSessionMeta[d.id] = meta;
    }
  }

  Future<void> _recordCurrentDeviceSessionMeta() async {
    final id = session?.deviceId;
    if (id == null) return;
    final meta = await DeviceSessionMetaStore.instance.captureCurrent(
      websocketConnected: _realtime.isConnected,
    );
    deviceSessionMeta[id] = meta;
    await DeviceSessionMetaStore.instance.set(id, meta);
  }

  DeviceSessionMeta? sessionMetaFor(String deviceId) => deviceSessionMeta[deviceId];

  String connectionLabelFor(DeviceInfo device) {
    if (device.isCurrent) {
      return _realtime.isConnected ? 'WebSocket · активно' : 'REST · ожидание WS';
    }
    if (isDeviceOnline(device)) return 'Недавняя активность';
    return 'Не в сети';
  }

  Future<void> revokeDeviceSession(String deviceId) async {
    final device = _findDevice(deviceId);
    if (device == null) return;
    if (device.isCurrent) {
      throw StateError('Нельзя завершить текущий сеанс');
    }
    try {
      await _api.revokeDevice(deviceId);
    } on ApiException catch (e) {
      if (e.statusCode != 404) rethrow;
      final others = devices.where((d) => !d.isCurrent).toList();
      if (others.length == 1 && others.first.id == deviceId) {
        await revokeOtherDevices();
        return;
      }
      rethrow;
    }
    deviceTrustProfiles.remove(deviceId);
    await _deviceTrustStore.removeProfile(deviceId);
    deviceSessionMeta.remove(deviceId);
    await DeviceSessionMetaStore.instance.remove(deviceId);
    devices = devices.where((d) => d.id != deviceId).toList();
    await SecurityLogService.instance.append(
      SecurityEvent(
        title: 'Сеанс завершён',
        subtitle: device.deviceName,
        at: DateTime.now(),
        icon: 'devices',
      ),
    );
    notifyListeners();
  }

  Future<void> _ensureCurrentDeviceTrusted() async {
    final currentId = session?.deviceId;
    if (currentId == null) return;
    final profile = deviceTrustProfiles[currentId] ?? DeviceTrustProfile.currentDevice;
    if (!profile.trusted) {
      await setDeviceTrustProfile(currentId, profile.copyWith(trusted: true), logEvent: false);
    } else if (!deviceTrustProfiles.containsKey(currentId)) {
      deviceTrustProfiles[currentId] = DeviceTrustProfile.currentDevice;
      await _deviceTrustStore.setProfile(currentId, DeviceTrustProfile.currentDevice);
    }
  }

  Future<void> _scanPendingLoginApprovals() async {
    if (session == null) return;
    final currentId = session!.deviceId;
    if (!deviceTrustFor(currentId).trusted) {
      pendingLoginApprovals = [];
      return;
    }

    final next = <LoginApprovalRequest>[];
    for (final device in devices) {
      if (device.isCurrent) continue;
      if (deviceTrustFor(device.id).trusted) continue;
      if (!LoginApprovalService.instance.isRecentLogin(device)) continue;
      if (await LoginApprovalService.instance.isDismissed(device.id)) continue;
      next.add(LoginApprovalRequest.fromDevice(device));
    }

    final had = pendingLoginApprovals.length;
    pendingLoginApprovals = next;
    if (next.length > had && next.isNotEmpty) {
      InAppNotificationService.instance.notify(
        InAppNotificationEvent(
          title: 'Новый вход',
          body: 'Подтвердите вход: ${next.first.deviceName}',
          playSound: true,
        ),
      );
    }
  }

  Future<void> approveLoginRequest(String deviceId) async {
    await setDeviceTrusted(deviceId, true);
    await LoginApprovalService.instance.dismissRequest(deviceId);
    await _publishLoginApprovalSignal(targetDeviceId: deviceId, granted: true);
    await _scanPendingLoginApprovals();
    await SecurityLogService.instance.append(
      SecurityEvent(
        title: 'Вход разрешён',
        subtitle: deviceId,
        at: DateTime.now(),
        icon: 'login',
      ),
    );
    notifyListeners();
  }

  Future<void> denyLoginRequest(String deviceId) async {
    await LoginApprovalService.instance.dismissRequest(deviceId);
    await _publishLoginApprovalSignal(targetDeviceId: deviceId, granted: false);
    await _scanPendingLoginApprovals();
    await SecurityLogService.instance.append(
      SecurityEvent(
        title: 'Вход отклонён',
        subtitle: deviceId,
        at: DateTime.now(),
        icon: 'login',
      ),
    );
    notifyListeners();
  }

  Future<void> recheckLoginApproval() async {
    if (session == null) return;
    if (!loginApprovalPending) return;
    if (deviceTrustFor(session!.deviceId).trusted) {
      await _completeLoginApproval();
    }
    notifyListeners();
  }

  Future<void> _completeLoginApproval() async {
    if (session == null) return;
    await LoginApprovalService.instance.clearAwaitingApproval(session!.deviceId);
    await _ensureCurrentDeviceTrusted();
    loginApprovalPending = false;
    notifyListeners();
  }

  Future<void> _handleLoginApprovalDenied() async {
    loginApprovalPending = false;
    await LoginApprovalService.instance.clearAwaitingApproval(session!.deviceId);
    await logout();
  }

  Future<void> _publishLoginApprovalSignal({required String targetDeviceId, required bool granted}) async {
    if (conversations.isEmpty) return;
    final conv = conversations.first;
    final payload = jsonEncode({
      'target_device_id': targetDeviceId,
      'granted': granted,
      'at': DateTime.now().toIso8601String(),
    });
    try {
      await _api.sendMessage(
        conversationId: conv.id,
        ciphertext: base64Encode(utf8.encode(payload)),
        contentType: 'login_approval_grant',
      );
    } catch (e) {
      DebugLog.instance.warn('auth', 'login approval signal failed: $e');
    }
  }

  Future<void> _handleLoginApprovalSignal(ChatMessage msg) async {
    if (session == null || msg.senderUserId != session!.userId) return;
    try {
      final payload = jsonDecode(utf8.decode(base64Decode(msg.ciphertext))) as Map<String, dynamic>;
      if (payload['target_device_id'] != session!.deviceId) return;
      final granted = payload['granted'] == true;
      if (granted) {
        await _completeLoginApproval();
      } else {
        await _handleLoginApprovalDenied();
      }
    } catch (e) {
      DebugLog.instance.warn('auth', 'login approval parse failed: $e');
    }
  }

  Future<void> _syncDeviceTrustProfiles() async {
    final currentId = session?.deviceId;
    final knownIds = devices.map((d) => d.id).toSet();
    deviceTrustProfiles.removeWhere((id, _) => !knownIds.contains(id));
    final hiddenDefault = await SettingsRuntime.instance.devicesHiddenAccessDefault();
    final requireApproval = await SettingsRuntime.instance.devicesRequireApproval();

    for (final device in devices) {
      if (!deviceTrustProfiles.containsKey(device.id)) {
        final awaiting = await LoginApprovalService.instance.isDeviceAwaitingApproval(device.id);
        if (device.isCurrent && !awaiting) {
          deviceTrustProfiles[device.id] = DeviceTrustProfile.currentDevice;
          await _deviceTrustStore.setProfile(device.id, DeviceTrustProfile.currentDevice);
        } else if (!device.isCurrent && !requireApproval && !awaiting) {
          // Auto-trust only when approval is not required.
          final profile = DeviceTrustProfile(
            trusted: true,
            privateModeAccess: hiddenDefault,
            secretRoomAccess: hiddenDefault,
          );
          deviceTrustProfiles[device.id] = profile;
          await _deviceTrustStore.setProfile(device.id, profile);
        } else if (!deviceTrustProfiles.containsKey(device.id)) {
          final profile = DeviceTrustProfile(
            trusted: false,
            privateModeAccess: hiddenDefault,
            secretRoomAccess: hiddenDefault,
          );
          deviceTrustProfiles[device.id] = profile;
          await _deviceTrustStore.setProfile(device.id, profile);
        }
      }
    }

    if (currentId != null && deviceTrustProfiles.containsKey(currentId)) {
      final awaiting = await LoginApprovalService.instance.isDeviceAwaitingApproval(currentId);
      if (!awaiting) {
        final current = deviceTrustProfiles[currentId]!;
        if (!current.trusted) {
          final fixed = current.copyWith(trusted: true);
          deviceTrustProfiles[currentId] = fixed;
          await _deviceTrustStore.setProfile(currentId, fixed);
        }
      }
    }
  }

  DeviceInfo? _findDevice(String deviceId) {
    for (final d in devices) {
      if (d.id == deviceId) return d;
    }
    return null;
  }

  DeviceTrustProfile deviceTrustFor(String deviceId) {
    final device = _findDevice(deviceId);
    if (device?.isCurrent == true) {
      return deviceTrustProfiles[deviceId] ?? DeviceTrustProfile.currentDevice;
    }
    return deviceTrustProfiles[deviceId] ?? DeviceTrustProfile.unknown;
  }

  Future<void> setDeviceTrustProfile(String deviceId, DeviceTrustProfile profile, {bool logEvent = true}) async {
    final device = _findDevice(deviceId);
    if (device == null) return;

    var next = profile;
    if (device.isCurrent) {
      next = next.copyWith(trusted: true);
    }
    if (!next.trusted) {
      next = next.copyWith(privateModeAccess: false, secretRoomAccess: false);
    }

    await _deviceTrustStore.setProfile(deviceId, next);
    deviceTrustProfiles[deviceId] = next;

    if (logEvent) {
      await SecurityLogService.instance.append(
        SecurityEvent(
          title: 'Настройки устройства обновлены',
          subtitle: '${device.deviceName}: ${next.trusted ? 'доверенное' : 'недоверенное'}',
          at: DateTime.now(),
          icon: 'devices',
        ),
      );
    }
    notifyListeners();
  }

  Future<void> setDeviceTrusted(String deviceId, bool trusted) async {
    final current = deviceTrustFor(deviceId);
    await setDeviceTrustProfile(deviceId, current.copyWith(trusted: trusted));
  }

  Future<void> setDevicePrivateModeAccess(String deviceId, bool allowed) async {
    final current = deviceTrustFor(deviceId);
    await setDeviceTrustProfile(deviceId, current.copyWith(privateModeAccess: allowed));
  }

  Future<void> setDeviceSecretRoomAccess(String deviceId, bool allowed) async {
    final current = deviceTrustFor(deviceId);
    await setDeviceTrustProfile(deviceId, current.copyWith(secretRoomAccess: allowed));
  }

  int get trustedDeviceCount => devices.where((d) => deviceTrustFor(d.id).trusted).length;

  /// Emergency Lock — see roadmap §4.
  Future<void> executeEmergencyLock(EmergencyLockLevel level) async {
    await DuressPolicyEngine.instance.handle(
      DuressTrigger.emergencyLock,
      controller: this,
      incrementCounter: false,
    );
    await EmergencyLockService.instance.recordLock(level);
    HiddenVaultSession.instance.lock();

    try {
      await revokeOtherDevices();
    } catch (_) {}

    if (level == EmergencyLockLevel.full || level == EmergencyLockLevel.critical) {
      await EmergencyLockService.instance.setNewLoginsBlocked(true);
      await LoginApprovalService.instance.setEnabled(true);
      await notificationSettings?.silenceAllForEmergency();
      deviceTrustProfiles.clear();
    }

    if (level == EmergencyLockLevel.critical) {
      await HiddenVaultSession.instance.wipe();
      final userId = session?.userId;
      if (userId != null) await _messageCache.clearUser(userId);
      await CryptoService.wipeLocalKeys();
      await AuthKeyPair.wipeLocal();
      crypto = null;
      authKeyPair = null;
      await EmergencyLockService.instance.setRecoveryLock(true);
    }

    await SecurityLogService.instance.append(
      SecurityEvent(
        title: 'Экстренная блокировка',
        subtitle: level.label,
        at: DateTime.now(),
        icon: 'lock',
      ),
    );

    await logout();
  }

  Future<void> clearEmergencyRecoveryLock() async {
    await EmergencyLockService.instance.clearAllFlags();
    await SecurityLogService.instance.append(
      SecurityEvent(
        title: 'Блокировка восстановления снята',
        subtitle: 'Вручную',
        at: DateTime.now(),
        icon: 'lock_open',
      ),
    );
  }

  Future<void> revokeOtherDevices() async {
    final currentId = session?.deviceId;
    await _api.revokeOtherDevices();
    final toRemove = deviceTrustProfiles.keys.where((id) => id != currentId).toList();
    for (final id in toRemove) {
      deviceTrustProfiles.remove(id);
      await _deviceTrustStore.removeProfile(id);
    }
    await refreshDevices();
    await SecurityLogService.instance.append(
      SecurityEvent(
        title: 'Завершены другие сеансы',
        subtitle: 'Удалено устройств: ${toRemove.length}',
        at: DateTime.now(),
        icon: 'devices',
      ),
    );
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _api.changePassword(currentPassword: currentPassword, newPassword: newPassword);
  }

  NetworkUsageStore get networkUsage => _api.networkUsage;

  Future<void> updateDisplayName(String newDisplayName) async {
    await _api.updateDisplayName(newDisplayName);
    session!.displayName = newDisplayName;
    knownDisplayNames[session!.userId] = newDisplayName;
    await _sessionStore.saveDisplayName(newDisplayName);
    notifyListeners();
  }

  Future<void> logout() async {
    final userId = session?.userId;
    _timeTasksTimer?.cancel();
    _timeTasksTimer = null;
    _realtimeSub?.cancel();
    _realtimeSub = null;
    _realtime.disconnect();
    if (userId != null) {
      await _messageCache.clearUser(userId);
      // Clear in-scope list while still namespaced to this user.
      await _localSettings.setStringList('hidden_conversations', []);
    }
    await _sessionStore.clear();
    _hiddenConversationIds.clear();
    if (currentCall != null) await _clearCall(currentCall!);
    loginApprovalPending = false;
    pendingLoginApprovals = [];
    session = null;
    conversations = [];
    messagesByConversation.clear();
    devices = [];
    unreadCounts.clear();
    chatMuted.clear();
    disappearingSeconds.clear();
    _secretSessionActive.clear();
    _secretPlaintextVault.clear();
    for (final t in _secretSessionTimers.values) {
      t.cancel();
    }
    _secretSessionTimers.clear();
    secretDisappearingSeconds = null;
    activeConversationId = null;
    phone = null;
    login = null;
    email = null;
    // Detach settings/PIN namespace so the next account starts clean.
    // Namespaced prefs for this userId remain for a later re-login.
    await AccountSettingsScope.deactivate();
    notifyListeners();
  }
}
