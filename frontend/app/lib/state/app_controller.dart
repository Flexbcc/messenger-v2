import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../calls/active_call.dart';
import '../config.dart';
import '../calls/call_media_controller.dart';
import '../calls/call_recovery_policy.dart';
import '../calls/call_signal.dart';
import '../calls/call_signaling_service.dart';
import '../crypto/auth_keypair.dart';
import '../crypto/crypto_service.dart';
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
import '../services/attachment_media_service.dart';
import '../services/authentication_service.dart';
import '../services/bootstrap_service.dart';
import '../services/call_history_runtime_service.dart';
import '../services/call_ice_service.dart';
import '../services/chat_preferences_store.dart';
import '../services/connection_status_service.dart';
import '../services/conversation_directory_service.dart';
import '../services/conversation_list_service.dart';
import '../services/conversation_reachability_service.dart';
import '../services/contact_runtime_service.dart';
import '../services/contact_interaction_policy.dart';
import '../services/contact_key_verification_service.dart';
import '../services/debug_log.dart';
import '../services/device_trust_runtime_service.dart';
import '../models/device_session_meta.dart';
import '../services/device_session_runtime_service.dart';
import '../models/emergency_lock_level.dart';
import '../services/emergency_lock_service.dart';
import '../services/hidden_chats_store.dart';
import '../services/hidden_vault_session.dart';
import '../services/home_failover_service.dart';
import '../services/login_approval_service.dart';
import '../services/login_approval_runtime_service.dart';
import '../services/local_settings_store.dart';
import '../services/local_message_history_restore_service.dart';
import '../services/media_cache.dart';
import '../services/persistent_media_store.dart';
import '../services/message_cache_store.dart';
import '../services/message_delivery_store.dart';
import '../services/message_local_actions_service.dart';
import '../services/message_encryption_service.dart';
import '../services/outbound_message_service.dart';
import '../services/message_decryption_support.dart';
import '../services/message_visibility_service.dart';
import '../services/in_app_notification_service.dart';
import '../services/node_config_resolver.dart';
import '../services/os_notification_service.dart';
import '../services/network_usage_store.dart';
import '../models/peer_home_entry.dart';
import '../services/peer_home_cache.dart';
import '../services/profile_service.dart';
import '../services/secret_chat_preferences_store.dart';
import '../services/secret_session_manager.dart';
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
import '../models/message_reminder.dart';
import '../services/favorites_service.dart';
import '../services/time_task_service.dart';
import '../utils/message_format.dart';
import '../utils/message_payload.dart';
import '../utils/favorites_chat.dart';
import '../utils/user_id.dart';
import '../utils/crypto_serial_queue.dart';
import '../services/realtime_service.dart';
import '../services/session_store.dart';
import '../services/session_restore_policy.dart';
import '../services/settings_runtime.dart';
import '../services/surb_delivery_store.dart';
import '../services/catalog_list_store.dart';
import '../services/web_push_service.dart';

part 'app_controller_devices.dart';
part 'app_controller_account_security.dart';
part 'app_controller_calls.dart';
part 'app_controller_privacy.dart';
part 'app_controller_secret_sessions.dart';
part 'app_controller_duress.dart';
part 'app_controller_realtime.dart';
part 'app_controller_e2ee_control.dart';
part 'app_controller_message_history.dart';
part 'app_controller_message_storage.dart';
part 'app_controller_crypto.dart';
part 'app_controller_outbound_messages.dart';

final appControllerProvider = ChangeNotifierProvider<AppController>(
  (ref) => AppController(),
);

/// Single pragmatic app-state holder for the MVP (see ADR-0004 — simplicity
/// over textbook layering while the product surface is still small).
class AppController extends ChangeNotifier {
  void _notifyStateChanged() => notifyListeners();

  final _sessionStore = SessionStore();
  static const _sessionRestorePolicy = SessionRestorePolicy();
  final _api = ApiClient();
  late final _authentication = AuthenticationService(_api, _sessionStore);
  late final _attachmentMedia = AttachmentMediaService(_api);
  late final _outboundMessages = OutboundMessageService(_api, _attachmentMedia);
  final _realtime = RealtimeService();
  StreamSubscription<Map<String, dynamic>>? _realtimeSub;
  static const _callOfferMaxAge = Duration(seconds: 90);
  final _chatPrefs = ChatPreferencesStore();
  final _callHistory = CallHistoryRuntimeService();
  late final _callIce = CallIceService(_api);
  final _contacts = ContactRuntimeService();
  final _interactionPolicy = ContactInteractionPolicy();
  final _deviceTrust = DeviceTrustRuntimeService();
  final _deviceSessions = DeviceSessionRuntimeService();
  final _loginApprovals = LoginApprovalRuntimeService();
  final _connectionStatus = const ConnectionStatusService();
  final _homeFailover = HomeFailoverService();
  late final _conversationDirectory = ConversationDirectoryService(
    _api,
    ConversationReachabilityService(_api),
  );
  final _conversationList = const ConversationListService();
  final _localSettings = LocalSettingsStore();
  late final _profile = ProfileService(_api, _localSettings, _sessionStore);
  final _messageCache = MessageCacheStore.instance;
  late final _localHistoryRestore = LocalMessageHistoryRestoreService(
    _messageCache,
  );
  final _messageVisibility = const MessageVisibilityService();
  final _messageLocalActions = MessageLocalActionsService();
  final _timeTasks = TimeTaskService();
  final _favorites = FavoritesService();
  final _uuid = const Uuid();
  // One queue for both encrypt and decrypt operations. Double Ratchet state is
  // mutable in both directions; serialising decrypt alone still allows a read
  // receipt and a text send to overwrite each other's session update.
  final _cryptoSessionQueue = CryptoSerialQueue();
  Future<void> _realtimeEventChain = Future<void>.value();
  bool _approvedRuntimeStarted = false;
  Timer? _timeTasksTimer;

  int scheduledMessageCount = 0;
  bool favoritesChatEnabled = true;

  /// Cached reachability per direct conversation (peer has prekey bundle on server).
  Map<String, bool> get conversationReachable =>
      _conversationDirectory.reachableByConversation;
  Map<String, String?> get conversationReachabilityError =>
      _conversationDirectory.errorByConversation;

  /// Injected from root UI after boot — see main.dart.
  NotificationSettings? notificationSettings;

  Session? session;
  CryptoService? crypto;
  AuthKeyPair? authKeyPair;

  /// Post-R5 client failover (docs/reality/R4-routing.md Gaps — "Нет client
  /// backup routes") state — see [_maybeFailoverHome]. [homeMovedMessage] is
  /// set when failover switched Home but the session couldn't be recovered
  /// there, so the user landed back on the login screen; the login screen
  /// shows it once, then callers should clear it.
  String? homeMovedMessage;
  String? get lastFailoverFromUrl => _homeFailover.lastFromUrl;
  String? get lastFailoverToUrl => _homeFailover.lastToUrl;
  DateTime? get lastFailoverAt => _homeFailover.lastSucceededAt;

  /// Most recent `home_changed` notify this session, if any — diagnostics/
  /// connection status display only (see PeerHomeCache, [_onRealtimeEvent]).
  String? get lastHomeChangedUserId => PeerHomeCache.instance.lastUserId;
  PeerHomeEntry? get lastHomeChangedEntry => PeerHomeCache.instance.lastEntry;

  /// Cached Home node URL for [userId] from the last `home_changed` notify
  /// we received about them, if any.
  Future<PeerHomeEntry?> peerHomeFor(String userId) =>
      PeerHomeCache.instance.get(userId);

  // Populated on demand by loadMyProfile() (see account_screen.dart) — not
  // fetched at boot/login to avoid slowing those down; phone/login/email
  // aren't needed until the user opens "Аккаунт".
  String? phone;
  String? login;
  String? email;
  String? bio;
  Uint8List? profileAvatarBytes;

  List<DeviceInfo> devices = [];

  bool booting = true;
  bool get isLoggedIn => session != null;

  List<Conversation> conversations = [];
  final Map<String, List<ChatMessage>> messagesByConversation = {};
  final Map<String, String> knownDisplayNames =
      {}; // local cache, see shared/README.md

  /// Conversation currently open in [ChatScreen] — used for read/unread tracking.
  String? activeConversationId;

  /// Cached unread counts per conversation (recomputed after reads/messages).
  final Map<String, int> unreadCounts = {};

  /// Cached per-chat prefs for synchronous UI reads.
  final Map<String, bool> chatMuted = {};
  final Map<String, int?> disappearingSeconds = {};

  /// Active secret-chat sessions per conversation (device-local).
  final _secretSessions = SecretSessionManager();
  int? secretDisappearingSeconds;

  /// Local call log (newest first).
  List<CallHistoryEntry> get callHistory => _callHistory.entries;

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
  final Set<String> _typingConversations = {};
  final Map<String, Timer> _typingTimers = {};
  Map<String, TrustLevel> get contactTrustLevels => _contacts.trustLevels;

  /// Per-device trust & Private Mode access — defaults applied in [deviceTrustFor].
  Map<String, DeviceTrustProfile> get deviceTrustProfiles =>
      _deviceTrust.profiles;

  /// Locally reported client metadata per device session.
  Map<String, DeviceSessionMeta> get deviceSessionMeta =>
      _deviceSessions.metadata;

  /// When conversations were last fetched from Home Node.
  DateTime? lastConversationSyncAt;

  bool get websocketConnected => _realtime.isConnected;

  /// Groups whose sender key has already been distributed to all members
  /// this session — see 0301_GROUP_MESSAGING.md. Reset on restart (in
  /// memory only), matching CryptoService's sender-key store lifetime.

  /// Locally hidden / pinned messages (device-only).
  /// The one call (incoming or outgoing) currently ringing/in progress —
  /// see spec/0303_CALLS.md, ADR-0008. Null when there is none.
  ActiveCall? currentCall;

  /// New device login blocked until approved on a trusted device.
  bool loginApprovalPending = false;

  /// Incoming login requests detected on this trusted device.
  List<LoginApprovalRequest> get pendingLoginApprovals =>
      _loginApprovals.pending;

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

  CryptoService get _requireCrypto =>
      crypto ?? (throw StateError('crypto is not initialized'));

  Session get _requireSession =>
      session ?? (throw StateError('not authenticated'));

  AuthKeyPair get _requireAuthKeyPair =>
      authKeyPair ??
      (throw StateError('authentication key is not initialized'));

  CallSignalingService get _callSignaling =>
      CallSignalingService(_requireCrypto);

  String _shortDebugId(String value) =>
      value.length <= 8 ? value : '${value.substring(0, 8)}…';

  Conversation? _findConversation(String id) {
    for (final c in conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Removes every account-derived value that must not survive a failed
  /// session restore or become visible to the next account in this process.
  void _clearAccountRuntimeState() {
    conversations = [];
    messagesByConversation.clear();
    devices = [];
    knownDisplayNames.clear();
    _contacts.clearRuntime();
    _deviceTrust.clearRuntime();
    _deviceSessions.clearRuntime();
    _loginApprovals.clearRuntime();
    _approvedRuntimeStarted = false;
    _callHistory.clearRuntime();
    _hiddenConversationIds.clear();
    _secretHiddenConversationIds.clear();
    _messageLocalActions.clear();
    unreadCounts.clear();
    chatMuted.clear();
    disappearingSeconds.clear();
    _secretSessions.dispose();
    HiddenVaultSession.instance.lock();
    DuressPolicySession.instance.lock();
    AppPrivacySession.instance.exit();
  }

  Future<void> boot() async {
    try {
      authKeyPair = await AuthKeyPair.loadOrCreate();
      crypto = await CryptoService.loadOrCreate();

      final existing = await _sessionStore.load();
      if (existing != null) {
        // Bind account namespace before reading aliases, trust, or any other
        // account-local preference.
        await AccountSettingsScope.activate(existing.userId);
        await _contacts.load();
        await _deviceTrust.load();
        await _callHistory.load();
        knownDisplayNames
          ..clear()
          ..addAll(_contacts.aliases);
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
      } else {
        _contacts.clearRuntime();
        _deviceTrust.clearRuntime();
        _callHistory.clearRuntime();
        knownDisplayNames.clear();
        _hiddenConversationIds.clear();
        _secretHiddenConversationIds.clear();
        HiddenVaultSession.instance.lock();
        DuressPolicySession.instance.lock();
        AppPrivacySession.instance.exit();
      }
      if (existing != null) {
        try {
          session = existing;
          _api.accessToken = existing.accessToken;
          await _loadPrivacyPolicies();
          await _loadMessageLocalActions();
          await _relogin();
          await _api.getMyProfile();
          await refreshConversations();
          _connectRealtime();
          loginApprovalPending = await LoginApprovalService.instance
              .isDeviceAwaitingApproval(session!.deviceId);
          if (!loginApprovalPending) {
            await refreshDevices();
          }
          _startTimeTasksTimer();
          unawaited(processTimeBasedTasks());
        } on ApiException catch (e) {
          final rejected = _sessionRestorePolicy.shouldClear(e);
          DebugLog.instance.warn(
            'auth',
            rejected
                ? 'stored session rejected with ${e.statusCode}'
                : 'session restore deferred after HTTP ${e.statusCode}',
          );
          // A temporary Home/Discovery failure must not erase the local
          // identity and force a new registration. `_relogin` already clears
          // credentials when the server explicitly rejects this device.
          if (rejected && session != null) {
            await _clearLocalSession();
          }
        } catch (e) {
          DebugLog.instance.error(
            'auth',
            'session restore deferred; local login retained: $e',
          );
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
    await _messageLocalActions.load(userId);
  }

  bool isMessagePinned(String messageId) =>
      _messageLocalActions.isPinned(messageId);

  Future<void> hideMessageLocally(String messageId) async {
    final userId = session?.userId;
    if (userId == null) return;
    await _messageLocalActions.hide(userId, messageId);
    notifyListeners();
  }

  Future<void> toggleMessagePinned(String messageId) async {
    final userId = session?.userId;
    if (userId == null) return;
    await _messageLocalActions.togglePinned(userId, messageId);
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
      await _challengeVerify();
    } on ApiException catch (error) {
      if (error.statusCode == 401 ||
          error.statusCode == 403 ||
          error.statusCode == 404) {
        await _clearLocalSession();
      }
      rethrow;
    } on TimeoutException {
      // Network-level failure (timeout/socket) — primary Home is likely
      // unreachable rather than just rejecting us. Give client failover
      // (Post-R5, docs/reality/R4-routing.md Gaps) a chance before giving
      // up on this refresh cycle.
      await _maybeFailoverHome();
    } on http.ClientException {
      await _maybeFailoverHome();
    }
  }

  /// Challenge/verify against the current [AppConfig.homeNodeUrl]. Throws
  /// [ApiException] when Home is reachable but rejects re-auth (unknown
  /// device/account on that node), or the underlying `http` exception
  /// (timeout/socket) when it isn't reachable at all — callers use that
  /// distinction to decide whether to attempt failover.
  Future<void> _challengeVerify() async {
    session!.accessToken = await _authentication.refreshSession(
      session: session!,
      authKeyPair: authKeyPair!,
    );
  }

  /// Post-R5 client failover (docs/reality/R4-routing.md Gaps — "Нет client
  /// backup routes"): [NodeConfigResolver] already probed backups' `/health`
  /// (R4 gap), but never switched the active Home or re-authenticated
  /// against it. This does both: swap the persisted primary `home_url` to
  /// the first reachable backup, point [AppConfig] at it, then try normal
  /// challenge/verify session recovery there. If recovery fails too (new
  /// Home doesn't know this device/account), fall back to the login screen
  /// with an explanation instead of looping on 401s.
  ///
  /// At most one attempt per outage episode: [_failoverInFlight] blocks
  /// concurrent callers (app resume + WS reconnect + relogin can all race
  /// each other onto this same path), and [_failoverCooldown] blocks repeat
  /// attempts for a while after one, whether it succeeded or not, so a
  /// hard-down cluster isn't hammered with `/health` probes on every retry.
  Future<bool> _maybeFailoverHome() async {
    if (session == null || authKeyPair == null) return false;
    final result = await _homeFailover.recoverSession(_challengeVerify);
    if (result == null) return false;
    if (!result.recovered) {
      await _forceLoginAfterFailedFailover(result.newHomeUrl);
    }
    notifyListeners();
    return result.recovered;
  }

  /// New Home doesn't recognize this device/account — rather than spinning
  /// on 401s against it, drop back to the login screen with an explanation
  /// (see [homeMovedMessage]) so the user can re-auth or pick another
  /// network/invite instead of staring at a stuck spinner.
  Future<void> _forceLoginAfterFailedFailover(String newHomeUrl) async {
    homeMovedMessage =
        'Домашний узел изменился на $newHomeUrl, и текущий сеанс там не найден. '
        'Войдите снова.';
    await _clearLocalSession();
  }

  Future<void> _clearLocalSession() async {
    _timeTasksTimer?.cancel();
    _timeTasksTimer = null;
    await _realtimeSub?.cancel();
    _realtimeSub = null;
    if (currentCall != null) {
      await _clearCall(currentCall!);
    }
    for (final timer in _typingTimers.values) {
      timer.cancel();
    }
    _typingTimers.clear();
    _typingConversations.clear();
    await _sessionStore.clear();
    session = null;
    _api.accessToken = null;
    _realtime.disconnect();
    loginApprovalPending = false;
    _loginApprovals.clearRuntime();
    activeConversationId = null;
    _clearAccountRuntimeState();
    await AccountSettingsScope.deactivate();
  }

  /// Best-effort pre-flight for [register]/[loginWithPassword]: if the
  /// persisted primary Home is unreachable and we have backups, swap to one
  /// *before* spending a login request against a dead node. This is a
  /// one-off opportunistic swap (no session to recover yet, so it doesn't
  /// share [_maybeFailoverHome]'s cooldown/in-flight guards) — failure here
  /// is never fatal, the login call below just fails normally and the
  /// screen surfaces that as its usual error.
  Future<void> _failoverBeforeLoginIfNeeded() async {
    await _homeFailover.preflight();
  }

  Future<void> register({
    required String displayName,
    required String phone,
    String? login,
    String? email,
    String? password,
  }) async {
    if (await EmergencyLockService.instance.isRecoveryLockActive()) {
      throw StateError('Аккаунт заблокирован. Требуется ключ восстановления.');
    }
    await _failoverBeforeLoginIfNeeded();
    final attempt = await _authentication.register(
      displayName: displayName,
      phone: phone,
      login: login,
      email: email,
      password: password,
    );
    authKeyPair = attempt.authKeyPair;
    crypto = attempt.crypto;
    await _finishLogin(attempt.response, displayName);
  }

  /// ADR-0007 temporary bridge login by phone/login/email + password.
  /// May attach as a new Device under an existing account.
  Future<void> loginWithPassword(String identifier, String password) async {
    if (!AppConfig.allowPasswordAuthBridge) {
      throw StateError(
        'Парольный вход отключён; используйте ключ устройства или QR',
      );
    }
    if (await EmergencyLockService.instance.isRecoveryLockActive()) {
      throw StateError('Аккаунт заблокирован. Требуется ключ восстановления.');
    }
    if (await EmergencyLockService.instance.areNewLoginsBlocked()) {
      throw StateError(
        'Новые входы заблокированы после экстренной блокировки.',
      );
    }
    await _failoverBeforeLoginIfNeeded();
    final attempt = await _authentication.loginWithPassword(
      identifier: identifier,
      password: password,
    );
    authKeyPair = attempt.authKeyPair;
    crypto = attempt.crypto;
    await _finishLogin(attempt.response, identifier, checkLoginApproval: true);
  }

  /// Re-enter after logout using only the device-held Ed25519 key.
  /// The server receives a nonce signature, never the private key.
  Future<void> loginWithLocalKey() async {
    await _failoverBeforeLoginIfNeeded();
    final result = await _authentication.loginWithLocalKey();
    authKeyPair = result.attempt.authKeyPair;
    crypto = result.attempt.crypto;
    await _finishLogin(result.attempt.response, result.displayName);
  }

  /// Starts a symmetric QR link on this not-yet-authorized device.
  Future<Map<String, dynamic>> createDeviceLink() async {
    await _failoverBeforeLoginIfNeeded();
    final attempt = await _authentication.createDeviceLink();
    authKeyPair = attempt.authKeyPair;
    crypto = attempt.crypto;
    return attempt.response;
  }

  /// Polls once; completes login when the trusted device approved the QR.
  Future<bool> pollDeviceLink(String linkId, String secret) async {
    final result = await _authentication.pollDeviceLink(
      linkId: linkId,
      secret: secret,
    );
    if (result['status'] != 'approved') return false;
    await _finishLogin(
      result,
      result['display_name'] as String? ?? 'OUO',
      checkLoginApproval: false,
    );
    return true;
  }

  Map<String, String> parseDeviceLinkPayload(String rawPayload) {
    return AuthenticationService.parseDeviceLinkPayload(rawPayload);
  }

  Future<Map<String, dynamic>> inspectDeviceLinkPayload(
    String rawPayload,
  ) async {
    final parsed = parseDeviceLinkPayload(rawPayload);
    return _authentication.inspectDeviceLink(
      linkId: parsed['link_id']!,
      secret: parsed['secret']!,
    );
  }

  Future<void> approveDeviceLinkPayload(String rawPayload) async {
    final parsed = parseDeviceLinkPayload(rawPayload);
    await _authentication.approveDeviceLink(
      linkId: parsed['link_id']!,
      secret: parsed['secret']!,
    );
    await refreshDevices();
  }

  Future<void> _finishLogin(
    Map<String, dynamic> result,
    String displayNameFallback, {
    bool checkLoginApproval = false,
  }) async {
    session = Session.fromAuthResponse(
      result,
      displayName: displayNameFallback,
    );
    _api.accessToken = session!.accessToken;
    await _sessionStore.save(
      userId: session!.userId,
      deviceId: session!.deviceId,
      accessToken: session!.accessToken,
      displayName: displayNameFallback,
    );
    homeMovedMessage = null;

    try {
      await AccountSettingsScope.activate(session!.userId);
      await _contacts.load();
      await _deviceTrust.load();
      await _callHistory.load();
      knownDisplayNames
        ..clear()
        ..addAll(_contacts.aliases)
        ..[session!.userId] = displayNameFallback;
      await _loadPrivacyPolicies();
      await _api.getPreKeyBundle(session!.userId);
    } on ApiException catch (e) {
      DebugLog.instance.error(
        'auth',
        'account not on home node after login: ${e.statusCode}',
      );
      await _sessionStore.clear();
      session = null;
      _api.accessToken = null;
      _clearAccountRuntimeState();
      await AccountSettingsScope.deactivate();
      throw StateError(
        'Аккаунт не найден на Home Node (${AppConfig.homeNodeUrl}). '
        'Возможно, запущено два сервера на порту 8001 — остановите лишний и зарегистрируйтесь снова.',
      );
    } catch (error) {
      DebugLog.instance.error(
        'auth',
        'login initialization failed; clearing local session',
        error,
      );
      await _sessionStore.clear();
      session = null;
      _api.accessToken = null;
      _clearAccountRuntimeState();
      if (LocalSettingsStore.activeUserId != null) {
        await AccountSettingsScope.deactivate();
      }
      rethrow;
    }

    await refreshDevices();
    await _recordCurrentDeviceSessionMeta();

    if (checkLoginApproval &&
        await LoginApprovalService.instance.isEnabled() &&
        _findDevice(session!.deviceId)?.serverTrusted != true) {
      await LoginApprovalService.instance.markDeviceAwaitingApproval(
        session!.deviceId,
      );
      loginApprovalPending = true;
    } else {
      await _ensureCurrentDeviceTrusted();
      loginApprovalPending = await LoginApprovalService.instance
          .isDeviceAwaitingApproval(session!.deviceId);
      if (loginApprovalPending &&
          _findDevice(session!.deviceId)?.serverTrusted == true) {
        await _completeLoginApproval();
      } else if (!loginApprovalPending) {
        await _startApprovedRuntime();
      }
    }

    DebugLog.instance.info(
      'auth',
      'logged in user=${session!.userId} device=${session!.deviceId}',
    );
    await SecurityMetaStore.instance.recordLogin();
    notifyListeners();
  }

  Future<void> _startApprovedRuntime() async {
    if (_approvedRuntimeStarted || session == null) return;
    _approvedRuntimeStarted = true;
    try {
      _connectRealtime();
      await _loadFavoritesPreferences();
      await _syncFavoritesChat();
      await refreshConversations();
      _startTimeTasksTimer();
      unawaited(processTimeBasedTasks());
    } catch (_) {
      _approvedRuntimeStarted = false;
      rethrow;
    }
  }

  void _startTimeTasksTimer() {
    _timeTasksTimer?.cancel();
    if (session == null) return;
    _timeTasksTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(processTimeBasedTasks());
    });
  }

  void _maybeNotifyMessage(ChatMessage msg, String convId) {
    if (msg.isSecret || msg.systemKind != null || msg.duressCode != null) {
      return;
    }

    final settings = notificationSettings;
    if (settings == null || session == null) return;
    final conv = _findConversation(convId);
    if (conv == null) return;

    if (_secretHiddenConversationIds.contains(convId) &&
        hiddenChatsSilenceNotifications) {
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

  Future<void> refreshConversations() async {
    final raw = await _api.listConversations();
    final me = session?.userId;
    final next = <Conversation>[];
    for (final j in raw) {
      final map = j;
      final conv = Conversation.fromJson(map);
      if (conv.isGroup &&
          me != null &&
          !_locallyCreatedGroupIds.contains(conv.id)) {
        final others = conv.participantUserIds.where((id) => id != me);
        var allowed = false;
        for (final peer in others) {
          final isContact =
              contactTrustLevels[peer] != null &&
              contactTrustLevels[peer] != TrustLevel.unknown;
          if (await SettingsRuntime.instance.groupInviteAllowed(
            peer,
            isContact: isContact,
          )) {
            allowed = true;
            break;
          }
        }
        if (!allowed && others.isNotEmpty) {
          DebugLog.instance.info(
            'chat',
            'group ${conv.id} ignored by privacy.group_invites',
          );
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
    _contacts.aliases.forEach((uid, label) {
      if (!isValidUserIdFormat(uid)) return;
      knownDisplayNames[uid] = label;
    });
    _sortConversations();
    await recomputeAllUnread();
    await validateAllConversationsReachability();
    _ensureTrustForConversationPeers();
    DebugLog.instance.info(
      'session',
      'user=$me conversations=${conversations.length}',
    );
    for (final c in conversations) {
      if (c.isGroup) continue;
      final peer = directPeerUserId(c);
      final ok = conversationReachable[c.id] == true;
      DebugLog.instance.info(
        'chat',
        '${_shortDebugId(c.id)} peer=$peer reachable=$ok',
      );
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
        _contacts.ensureDefaultTrust(uid);
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

  /// Sending uses the authenticated HTTP API. Realtime improves incoming
  /// delivery and presence, but a transient WebSocket outage must not disable
  /// outbound messages while Home Node remains reachable.
  bool get canSendMessages => session != null;

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
    _conversationList.sortInPlace(conversations, messagesByConversation);
  }

  List<Conversation> get sortedConversations => _conversationList.visibleSorted(
    conversations: conversations,
    messagesByConversation: messagesByConversation,
    locallyHiddenIds: _hiddenConversationIds,
    secretHiddenIds: _secretHiddenConversationIds,
  );

  /// Chats for the main list — optionally includes local «Избранное» at the top.
  /// In decoy mode, only explicitly selected decoy chats are visible.
  List<Conversation> get conversationsForList {
    var list = sortedConversations;
    if (AppPrivacySession.instance.isInDecoyMode) {
      final allow = _fakeProfileChatIds.toSet();
      list = list.where((c) => allow.contains(c.id)).toList();
    }
    final fav = visibleFavoritesConversation;
    if (fav == null) return list;
    if (AppPrivacySession.instance.isInDecoyMode) {
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
    return _conversationList.matchingSearch(
      query: query,
      visible: conversationsForList,
      additionallySearchable:
          !hiddenChatsExcludeFromSearch && hiddenChatsEnabled
          ? secretHiddenConversations
          : const [],
      titleFor: conversationTitle,
    );
  }

  Conversation? get visibleFavoritesConversation {
    return _favorites.visibleConversation(
      enabled: favoritesChatEnabled,
      userId: session?.userId,
      messages: messagesByConversation[FavoritesChat.id],
    );
  }

  int get favoritesCount =>
      messagesByConversation[FavoritesChat.id]?.length ?? 0;

  Future<void> _loadFavoritesPreferences() async {
    favoritesChatEnabled = await _favorites.isEnabled();
  }

  Future<void> setFavoritesChatEnabled(bool enabled) async {
    favoritesChatEnabled = enabled;
    await _favorites.setEnabled(enabled);
    notifyListeners();
  }

  Future<void> _syncFavoritesChat() async {
    messagesByConversation[FavoritesChat.id] = await _favorites.loadMessages();
  }

  Future<void> refreshFavoritesChat() => _syncFavoritesChat();

  Future<void> removeFavorite(String favoriteId) async {
    messagesByConversation[FavoritesChat.id] = await _favorites.remove(
      favoriteId,
    );
    notifyListeners();
  }

  Conversation? conversationById(String id) {
    if (FavoritesChat.isId(id)) return visibleFavoritesConversation;
    return _findConversation(id);
  }

  List<Conversation> get secretHiddenConversations =>
      _conversationList.secretHiddenSorted(
        conversations: conversations,
        messagesByConversation: messagesByConversation,
        secretHiddenIds: _secretHiddenConversationIds,
        sortByName: hiddenChatsSort == HiddenChatSort.name,
        titleFor: conversationTitle,
      );

  bool isSecretHidden(String conversationId) =>
      _secretHiddenConversationIds.contains(conversationId);

  bool isLocallyHidden(String conversationId) =>
      _hiddenConversationIds.contains(conversationId);

  Future<void> scheduleTextMessage({
    required Conversation conversation,
    required String text,
    required DateTime sendAt,
    String? replyToMessageId,
    String? replyPreview,
  }) async {
    scheduledMessageCount = await _timeTasks.scheduleMessage(
      conversationId: conversation.id,
      text: text.trim(),
      sendAt: sendAt,
      replyToMessageId: replyToMessageId,
      replyPreview: replyPreview,
    );
    notifyListeners();
  }

  Future<void> cancelScheduledMessage(String id) async {
    scheduledMessageCount = await _timeTasks.cancelScheduledMessage(id);
    notifyListeners();
  }

  Future<void> addFavoriteMessage(
    Conversation conversation,
    ChatMessage message,
  ) async {
    final me = session?.userId;
    final senderLabel = message.senderUserId == me
        ? 'Вы'
        : labelFor(message.senderUserId);
    messagesByConversation[FavoritesChat.id] = await _favorites.add(
      conversationId: conversation.id,
      conversationTitle: conversationTitle(conversation),
      message: message,
      preview: messagePreview(message),
      senderLabel: senderLabel,
    );
    notifyListeners();
  }

  Future<void> addMessageReminder({
    required Conversation conversation,
    required ChatMessage message,
    required DateTime remindAt,
  }) async {
    await _timeTasks.addReminder(
      conversationId: conversation.id,
      messageId: message.id,
      preview: messagePreview(message),
      remindAt: remindAt,
    );
    notifyListeners();
  }

  Future<void> processTimeBasedTasks() async {
    if (session == null) return;
    try {
      await refreshDevices();
    } catch (_) {
      // Device approval discovery retries on the next background tick.
    }
    scheduledMessageCount = await _timeTasks.processScheduled((item) async {
      final conv = _findConversation(item.conversationId);
      if (conv == null) return true;
      try {
        await sendText(
          conv,
          item.text,
          replyToMessageId: item.replyToMessageId,
          replyPreview: item.replyPreview,
        );
        return true;
      } catch (e) {
        DebugLog.instance.error('schedule', 'failed ${item.id}: $e');
        return false;
      }
    });
    await _timeTasks.processReminders(_applyReminder);
  }

  Future<void> _applyReminder(MessageReminder reminder) async {
    final msgs = messagesByConversation[reminder.conversationId] ?? [];
    final target = msgs.where((m) => m.id == reminder.messageId).firstOrNull;
    if (target != null) {
      final before = target.createdAt.subtract(const Duration(seconds: 1));
      await _chatPrefs.setLastRead(reminder.conversationId, before);
      await recomputeUnread(reminder.conversationId);
    } else {
      unreadCounts[reminder.conversationId] =
          (unreadCounts[reminder.conversationId] ?? 0) + 1;
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

  String labelFor(String userId) {
    return _conversationDirectory.labelFor(
      userId,
      currentUserId: session?.userId,
      knownDisplayNames: knownDisplayNames,
    );
  }

  Conversation? conversationLabelSource(Conversation c) => c;

  String conversationTitle(Conversation c) {
    return _conversationDirectory.titleFor(
      c,
      currentUserId: session?.userId,
      knownDisplayNames: knownDisplayNames,
    );
  }

  String? directPeerUserId(Conversation conversation) {
    return _conversationDirectory.directPeerUserId(
      conversation,
      currentUserId: session?.userId,
    );
  }

  Future<void> _ensureDirectConversationNotBlocked(
    Conversation conversation,
  ) async {
    if (conversation.isGroup) return;
    final peer = directPeerUserId(conversation);
    if (peer != null && !await _interactionPolicy.canInitiate(peer)) {
      throw StateError('Контакт заблокирован');
    }
  }

  Conversation? findDirectConversationWith(String peerUserId) {
    return _conversationDirectory.findDirectConversation(
      conversations,
      peerUserId: peerUserId,
      currentUserId: session?.userId,
    );
  }

  Future<void> validateConversationReachability(
    Conversation conversation,
  ) async {
    final reachablePeer = await _conversationDirectory.validateReachability(
      conversation,
      currentUserId: session?.userId,
    );
    if (reachablePeer != null) await refreshContactPresence(reachablePeer);
    notifyListeners();
  }

  Future<void> validateAllConversationsReachability() async {
    for (final c in conversations) {
      await validateConversationReachability(c);
    }
  }

  bool isConversationReachable(Conversation conversation) {
    return _conversationDirectory.isReachable(conversation);
  }

  String? reachabilityErrorFor(Conversation conversation) =>
      conversationReachabilityError[conversation.id];

  Future<String> verifyPeerUserId(String rawUserId) async {
    return _conversationDirectory.verifyPeerUserId(
      rawUserId,
      currentUserId: session?.userId,
    );
  }

  Future<Conversation> startDirectChat(
    String otherUserId,
    String otherDisplayName,
  ) async {
    final id = await verifyPeerUserId(otherUserId);
    knownDisplayNames[id] = otherDisplayName.trim().isEmpty
        ? labelFor(id)
        : otherDisplayName.trim();
    if (!contactTrustLevels.containsKey(id)) {
      await setContactTrustLevel(id, TrustLevel.normal, logEvent: false);
    }

    final existing = findDirectConversationWith(id);
    if (existing != null) {
      DebugLog.instance.info(
        'chat',
        'reuse existing direct conversation ${existing.id} with $id',
      );
      await validateConversationReachability(existing);
      return existing;
    }

    DebugLog.instance.info('chat', 'create direct conversation with $id');
    final json = await _api.createConversation(
      type: 'direct',
      participantUserIds: [id],
    );
    final conv = Conversation.fromJson(json);
    await refreshConversations();
    await validateConversationReachability(conv);
    return conv;
  }

  Future<Conversation> startGroupChat(
    String name,
    List<MapEntry<String, String>> members,
  ) async {
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

  /// Opens an existing 1:1 chat or creates one using the locally known name.
  Conversation? findDirectConversation(String otherUserId) {
    for (final c in conversations) {
      if (!c.isGroup &&
          c.participantUserIds.contains(otherUserId) &&
          c.participantUserIds.length == 2) {
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
    await _contacts.setAlias(userId, name);
    knownDisplayNames[userId] = name.trim();
    notifyListeners();
  }

  TrustLevel trustLevelFor(String userId) => _contacts.trustLevelFor(userId);

  Future<void> setContactTrustLevel(
    String userId,
    TrustLevel level, {
    bool logEvent = true,
  }) async {
    final verification = ContactKeyVerificationService();
    if (level.index >= TrustLevel.trusted.index) {
      if (!await verification.hasCurrentVerification(userId)) {
        throw StateError('Ключи контакта изменились или ещё не были проверены');
      }
    } else {
      await verification.clearVerification(userId);
    }
    await _contacts.setTrust(userId, level);
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
    return _contacts.lastActivity(
      userId,
      messageLists: messagesByConversation.values,
      calls: callHistory,
    );
  }

  bool isContactOnline(String userId) => _contacts.isOnline(userId);

  String contactStatusLabel(String userId) {
    final call = currentCall;
    return _contacts.statusLabel(
      userId,
      isCurrentCallPeer: call?.peerUserId == userId,
      callAnswered: call?.answered ?? false,
    );
  }

  Future<void> refreshContactPresence(String userId) async {
    if (session == null || userId == session!.userId) return;
    try {
      final presence = await _api.getPresence(userId);
      _contacts.updatePresence(userId, presence);
      notifyListeners();
    } catch (e) {
      DebugLog.instance.warn('presence', 'lookup failed for $userId: $e');
    }
  }

  Future<Uint8List> resolveImageBytes(
    ChatMessage message, {
    bool forceDownload = false,
  }) async {
    return resolveAttachmentBytes(message, forceDownload: forceDownload);
  }

  Future<Uint8List> resolveAttachmentBytes(
    ChatMessage message, {
    bool forceDownload = false,
  }) async {
    final currentSession = _requireSession;
    return _attachmentMedia.resolve(
      message,
      userId: currentSession.userId,
      authKeyPair: _requireAuthKeyPair,
      forceDownload: forceDownload,
      isolateFromMemoryCache: await SettingsRuntime.instance
          .shouldIsolateHiddenMedia(
            isSecretHidden: isSecretHidden(message.conversationId),
          ),
    );
  }

  Future<void> logout() async {
    final userId = session?.userId;
    var keepLocalData = true;
    try {
      keepLocalData = await SettingsRuntime.instance.keepLocalDataOnLogout();
    } catch (error) {
      DebugLog.instance.warn(
        'logout',
        'local-data preference unavailable; preserving account data',
        error,
      );
    }
    final pushCleanup = disableWebPush();
    _timeTasksTimer?.cancel();
    _timeTasksTimer = null;
    _realtimeSub?.cancel();
    _realtimeSub = null;
    _realtime.disconnect();
    session = null;
    _api.accessToken = null;
    loginApprovalPending = false;
    _loginApprovals.clearRuntime();
    activeConversationId = null;
    notifyListeners();

    // Credentials are the security boundary of logout. Clear them before
    // optional cache work so a broken SQLite/media backend cannot retain an
    // otherwise restorable authenticated session.
    try {
      await _sessionStore.clear();
    } catch (error) {
      DebugLog.instance.error(
        'logout',
        'session credential cleanup failed',
        error,
      );
    }
    try {
      await pushCleanup;
    } catch (error) {
      DebugLog.instance.error('logout', 'Push cleanup failed', error);
    }
    if (userId != null && !keepLocalData) {
      try {
        await _messageCache.clearUser(userId);
      } catch (error) {
        DebugLog.instance.warn('logout', 'message cache cleanup failed', error);
      }
      try {
        await PersistentMediaStore.instance.clearUser(userId);
      } catch (error) {
        DebugLog.instance.warn('logout', 'media cache cleanup failed', error);
      }
      // Clear in-scope list while still namespaced to this user.
      try {
        await _localSettings.setStringList('hidden_conversations', []);
      } catch (error) {
        DebugLog.instance.warn(
          'logout',
          'hidden conversation cleanup failed',
          error,
        );
      }
    }
    _hiddenConversationIds.clear();
    if (currentCall != null) {
      try {
        await _clearCall(currentCall!);
      } catch (error) {
        DebugLog.instance.warn('logout', 'active call cleanup failed', error);
      }
    }
    _clearAccountRuntimeState();
    for (final timer in _typingTimers.values) {
      timer.cancel();
    }
    _typingTimers.clear();
    _typingConversations.clear();
    secretDisappearingSeconds = null;
    activeConversationId = null;
    phone = null;
    login = null;
    email = null;
    // Detach settings/PIN namespace so the next account starts clean.
    // Namespaced prefs for this userId remain for a later re-login.
    try {
      await AccountSettingsScope.deactivate();
    } catch (error) {
      DebugLog.instance.warn('logout', 'settings scope cleanup failed', error);
    }
    notifyListeners();
  }
}
