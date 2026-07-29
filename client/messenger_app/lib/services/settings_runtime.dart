import 'package:flutter/foundation.dart';

import 'catalog_list_store.dart';
import 'duress_rate_limiter.dart';
import 'local_settings_store.dart';
import 'settings_catalog_bridge.dart';

/// Runtime policy engine — every catalog setting should be read through here.
class SettingsRuntime {
  SettingsRuntime({
    CatalogSettingsReader? reader,
    CatalogListStore? lists,
  })  : _reader = reader ?? CatalogSettingsReader(),
        _lists = lists ?? CatalogListStore();

  static final instance = SettingsRuntime();

  final CatalogSettingsReader _reader;
  final CatalogListStore _lists;

  // ── Profile ────────────────────────────────────────────────────────────────

  Future<String> displayName() => _reader.getString('profile.display_name', '');
  Future<bool> usernameEnabled() => _reader.getBool('profile.username_enabled', false);
  Future<String> username() => _reader.getString('profile.username', '');
  Future<String> bio() => _reader.getString('profile.bio', '');
  Future<String> language() => _reader.getString('profile.language', 'ru');
  Future<String> timeFormat() => _reader.getString('profile.time_format', '24h');
  Future<String> dateFormat() => _reader.getString('profile.date_format', 'DD.MM.YYYY');

  // ── Identity ───────────────────────────────────────────────────────────────

  Future<bool> phoneEnabled() => _reader.getBool('identity.phone_enabled', false);
  Future<String> phone() => _reader.getString('identity.phone', '');
  Future<bool> phoneLogin() => _reader.getBool('identity.phone_login', false);
  Future<bool> phoneRecovery() => _reader.getBool('identity.phone_recovery', false);
  Future<bool> emailEnabled() => _reader.getBool('identity.email_enabled', false);
  Future<String> email() => _reader.getString('identity.email', '');
  Future<bool> emailLogin() => _reader.getBool('identity.email_login', false);
  Future<bool> emailRecovery() => _reader.getBool('identity.email_recovery', false);

  /// No server verification API yet — treat non-empty bound value as verified.
  Future<bool> phoneVerified() async {
    if (!await phoneEnabled()) return false;
    return (await phone()).trim().isNotEmpty;
  }

  Future<bool> emailVerified() async {
    if (!await emailEnabled()) return false;
    return (await email()).trim().isNotEmpty;
  }

  // ── Privacy ──────────────────────────────────────────────────────────────

  Future<bool> readReceiptsEnabled() async {
    if (!await _reader.getBool('privacy.read_receipts', true)) return false;
    return _reader.getBool('messages.read_receipts_override', true);
  }

  Future<bool> typingEnabled() => _reader.getBool('privacy.typing_status', true);
  Future<bool> onlineStatusEnabled() => _reader.getBool('privacy.online_status', true);
  Future<bool> invisibleMode() => _reader.getBool('privacy.invisible_mode', false);
  Future<String> lastSeenPolicy() => _reader.getString('privacy.last_seen', 'contacts');
  Future<bool> usernameSearchAllowed() => _reader.getBool('privacy.username_search', true);
  Future<String> phoneSearchPolicy() => _reader.getString('privacy.phone_search', 'nobody');
  Future<bool> readReceiptsVisible() => _reader.getBool('privacy.read_receipts', true);

  Future<String> phoneVisibilityPolicy() =>
      _reader.getString('privacy.phone_visibility', 'nobody');
  Future<String> emailVisibilityPolicy() =>
      _reader.getString('privacy.email_visibility', 'nobody');
  Future<String> avatarVisibilityPolicy() =>
      _reader.getString('privacy.avatar_visibility', 'contacts');

  /// Whether peers may discover us via phone search (outbound gate in new-chat).
  Future<bool> phoneSearchAllowed() async {
    final policy = await phoneSearchPolicy();
    return policy != 'nobody';
  }

  Future<bool> voiceRecordStatusEnabled() =>
      _reader.getBool('privacy.voice_record_status', true);

  Future<String> groupInvitesPolicy() =>
      _reader.getString('privacy.group_invites', 'contacts');

  Future<bool> qrOnlyMode() => _reader.getBool('privacy.qr_only', false);
  Future<String> qrMode() => _reader.getString('privacy.qr_mode', 'temporary');
  Future<int> qrTtlMinutes() => _reader.getInt('privacy.qr_ttl_minutes', 30);

  Future<bool> canShowPhone(String viewerUserId, {required bool isContact}) async {
    return _visibilityAllows(
      policy: await phoneVisibilityPolicy(),
      listId: 'privacy.phone_visibility_list',
      viewerUserId: viewerUserId,
      isContact: isContact,
    );
  }

  Future<bool> canShowEmail(String viewerUserId, {required bool isContact}) async {
    return _visibilityAllows(
      policy: await emailVisibilityPolicy(),
      listId: 'privacy.email_visibility_list',
      viewerUserId: viewerUserId,
      isContact: isContact,
    );
  }

  Future<bool> canShowAvatar(String viewerUserId, {required bool isContact}) async {
    return switch (await avatarVisibilityPolicy()) {
      'nobody' => false,
      'everyone' => true,
      _ => isContact,
    };
  }

  Future<bool> groupInviteAllowed(String inviterId, {required bool isContact}) async {
    return switch (await groupInvitesPolicy()) {
      'nobody' => false,
      'everyone' => true,
      _ => isContact,
    };
  }

  /// Share / export fields for the local profile, honoring visibility + QR-only.
  Future<Map<String, dynamic>> buildShareableProfilePayload({
    required String userId,
    required String displayName,
    String? phone,
    String? email,
    String? username,
    String? avatarUrl,
    String viewerUserId = '',
    bool isContact = false,
  }) async {
    if (await qrOnlyMode()) {
      final ttl = await qrTtlMinutes();
      final mode = await qrMode();
      final expires = mode == 'permanent'
          ? null
          : DateTime.now().add(Duration(minutes: ttl)).toIso8601String();
      return {
        'kind': 'profile_qr',
        'user_id': userId,
        'qr_mode': mode,
        if (expires != null) 'expires_at': expires,
      };
    }
    final out = <String, dynamic>{
      'kind': 'profile',
      'user_id': userId,
      'display_name': displayName,
    };
    if (username != null && username.isNotEmpty) out['username'] = username;
    if (phone != null &&
        phone.isNotEmpty &&
        await canShowPhone(viewerUserId, isContact: isContact)) {
      out['phone'] = phone;
    }
    if (email != null &&
        email.isNotEmpty &&
        await canShowEmail(viewerUserId, isContact: isContact)) {
      out['email'] = email;
    }
    if (avatarUrl != null &&
        avatarUrl.isNotEmpty &&
        await canShowAvatar(viewerUserId, isContact: isContact)) {
      out['avatar'] = avatarUrl;
    }
    return out;
  }

  Future<bool> canShowOnlineStatus(String viewerUserId, {required bool isContact}) async {
    if (await invisibleMode()) return false;
    if (!await onlineStatusEnabled()) return false;
    return _visibilityAllows(
      policy: await lastSeenPolicy(),
      listId: 'privacy.last_seen_list',
      viewerUserId: viewerUserId,
      isContact: isContact,
    );
  }

  Future<bool> canShowLastSeen(String viewerUserId, {required bool isContact}) async {
    if (await invisibleMode()) return false;
    return _visibilityAllows(
      policy: await lastSeenPolicy(),
      listId: 'privacy.last_seen_list',
      viewerUserId: viewerUserId,
      isContact: isContact,
    );
  }

  Future<bool> _visibilityAllows({
    required String policy,
    required String listId,
    required String viewerUserId,
    required bool isContact,
  }) async {
    return switch (policy) {
      'nobody' => false,
      'contacts' => isContact,
      'selected' => (await _lists.load(listId)).contains(viewerUserId),
      'everyone' => true,
      _ => isContact,
    };
  }

  Future<bool> incomingMessagesAllowed(String senderId, {required bool isContact}) async {
    final policy = await _reader.getString('privacy.incoming_messages', 'invites');
    return switch (policy) {
      'nobody' => false,
      'contacts' => isContact,
      'invites' => true,
      _ => true,
    };
  }

  Future<bool> callsAllowed(String callerId, {required bool isContact}) async {
    final policy = await _reader.getString('privacy.calls_from', 'contacts');
    return _visibilityAllows(
      policy: policy,
      listId: 'privacy.calls_allowlist',
      viewerUserId: callerId,
      isContact: isContact,
    );
  }

  // ── Security (extended) ──────────────────────────────────────────────────

  Future<int> pinLength() async {
    final raw = await _reader.getString('security.pin_length', '6');
    return int.tryParse(raw) ?? 6;
  }

  Future<bool> alphanumericPassword() =>
      _reader.getBool('security.alphanumeric_password', false);

  Future<bool> lockOnScreenOff() =>
      _reader.getBool('security.lock_on_screen_off', true);

  Future<String> pinAttemptPolicyLabel() async {
    final wipe = await _reader.getBool('security.wipe_enabled', false);
    final after = await _reader.getString('security.wipe_after', '5');
    return DuressRateLimiter.policyLabel(wipeEnabled: wipe, wipeAfter: after);
  }

  Future<List<String>> fakeProfileChats() => _lists.load('security.fake_profile_chats');

  Future<bool> distressSignalEnabled() =>
      _reader.getBool('security.distress_signal', false);

  Future<List<String>> distressContacts() => _lists.load('security.distress_contacts');

  Future<bool> recoveryKeyEnabled() =>
      _reader.getBool('security.recovery_key_enabled', false);

  Future<List<String>> requirePinForCritical() async {
    final saved = await _reader.getStringList('security.require_pin_for_critical');
    if (saved.isNotEmpty) return saved;
    return const ['export', 'add_device', 'view_keys'];
  }

  Future<bool> requiresPinFor(String actionToken) async {
    if (!await _reader.getBool('security.pin_enabled', false)) return false;
    final list = await requirePinForCritical();
    return list.contains(actionToken);
  }

  // ── Hidden chats ─────────────────────────────────────────────────────────

  Future<bool> hiddenEnabled() => _reader.getBool('hidden.enabled', false);

  /// `pin` | `gesture` | `secret_command` | `calculator_screen`
  Future<String> hiddenOpenMethod() => _reader.getString('hidden.open_method', 'pin');

  Future<bool> hiddenHideFromSearch() => _reader.getBool('hidden.hide_from_search', true);
  Future<bool> hiddenHideNotifications() => _reader.getBool('hidden.hide_notifications', true);
  Future<bool> hiddenHideMedia() => _reader.getBool('hidden.hide_media', true);

  /// Catalog token: `immediately` | `30s` | `1m` | `5m` | `15m`
  Future<String> hiddenAutolock() => _reader.getString('hidden.autolock', '1m');

  Future<Duration> hiddenAutolockDuration() async {
    return switch (await hiddenAutolock()) {
      'immediately' => Duration.zero,
      '30s' => const Duration(seconds: 30),
      '5m' => const Duration(minutes: 5),
      '15m' => const Duration(minutes: 15),
      _ => const Duration(minutes: 1),
    };
  }

  Future<List<String>> hiddenChatList() => _lists.load('hidden.chat_list');

  Future<bool> hiddenGestureEntryAllowed() async {
    if (!await hiddenEnabled()) return false;
    final method = await hiddenOpenMethod();
    return method == 'gesture';
  }

  Future<bool> hiddenSecretCommandAllowed() async {
    if (!await hiddenEnabled()) return false;
    final method = await hiddenOpenMethod();
    return method == 'secret_command';
  }

  Future<bool> hiddenPinGateRequired() async {
    if (!await hiddenEnabled()) return false;
    final method = await hiddenOpenMethod();
    return method == 'pin' || method == 'calculator_screen';
  }

  /// When true, media from secret-hidden chats must stay out of the shared cache/gallery.
  Future<bool> shouldIsolateHiddenMedia({required bool isSecretHidden}) async {
    if (!isSecretHidden) return false;
    if (!await hiddenEnabled()) return false;
    return hiddenHideMedia();
  }

  // ── Contacts ─────────────────────────────────────────────────────────────

  Future<bool> isBlocked(String userId) async {
    final blocked = await _lists.load('contacts.blocked_list');
    return blocked.contains(userId);
  }

  Future<bool> contactsImportEnabled() => _reader.getBool('contacts.import_enabled', false);
  Future<bool> contactsHashLookup() => _reader.getBool('contacts.hash_lookup', true);
  Future<bool> contactsAutoAddMutual() => _reader.getBool('contacts.auto_add_mutual', false);
  Future<bool> contactsTrustedEnabled() => _reader.getBool('contacts.trusted_enabled', false);

  Future<bool> isTrustedContact(String userId) async {
    if (!await contactsTrustedEnabled()) return false;
    final trusted = await _lists.load('contacts.trusted_list');
    return trusted.contains(userId);
  }

  Future<bool> contactsTrustLevelsEnabled() =>
      _reader.getBool('contacts.trust_levels_enabled', true);

  Future<List<String>> contactsAllowedTrustLevels() async {
    final saved = await _reader.getStringList('contacts.trust_levels');
    if (saved.isNotEmpty) return saved;
    return const [
      'unknown',
      'unverified',
      'contact',
      'qr_verified',
      'trusted',
      'blocked',
    ];
  }

  Future<bool> keyChangeWarning() => _reader.getBool('contacts.key_change_warning', true);
  Future<bool> blockOnKeyChange() => _reader.getBool('contacts.block_on_key_change', false);

  Future<void> blockUser(String userId) async {
    await _lists.add('contacts.blocked_list', userId);
  }

  // ── Messages ─────────────────────────────────────────────────────────────

  Future<String> sendKey() => _reader.getString('messages.send_key', 'enter');
  Future<bool> draftsEnabled() => _reader.getBool('messages.save_drafts', true);
  Future<bool> confirmDelete() => _reader.getBool('messages.confirm_delete', true);
  Future<String> linkPreviewMode() => _reader.getString('messages.link_preview', 'local_only');
  Future<bool> linkPreviewEnabled() async {
    final mode = await linkPreviewMode();
    return mode != 'off';
  }

  Future<bool> confirmLargeFiles() => _reader.getBool('messages.confirm_large_files', true);
  Future<int> largeFileConfirmMb() => _reader.getInt('messages.large_file_mb', 100);

  /// True when [bytesLength] exceeds the large-file threshold and confirm is on.
  Future<bool> shouldConfirmLargeFile(int bytesLength) async {
    if (!await confirmLargeFiles()) return false;
    final mb = await largeFileConfirmMb();
    return bytesLength > mb * 1024 * 1024;
  }

  Future<bool> autoDeleteEnabled() => _reader.getBool('messages.auto_delete_enabled', false);
  Future<String> autoDeleteTtl() => _reader.getString('messages.auto_delete_ttl', '7d');

  /// Catalog TTL in seconds when auto-delete is enabled; otherwise null.
  Future<int?> outgoingAutoDeleteSeconds() async {
    if (!await autoDeleteEnabled()) return null;
    return parseTtlSeconds(await autoDeleteTtl());
  }

  // ── Media ────────────────────────────────────────────────────────────────

  Future<int> maxAutoloadMb() => _reader.getInt('media.max_autoload_mb', 20);
  Future<String> imageQuality() => _reader.getString('media.image_quality', 'balanced');
  Future<String> videoQuality() => _reader.getString('media.video_quality', 'balanced');
  Future<int> cacheLimitGb() => _reader.getInt('media.cache_limit_gb', 2);
  Future<bool> autoCleanup() => _reader.getBool('media.auto_cleanup', true);
  Future<String> autoCleanupAfter() => _reader.getString('media.auto_cleanup_after', '30d');
  Future<bool> saveToGallery() => _reader.getBool('media.save_to_gallery', false);

  /// Parse catalog TTL tokens (`1h`, `7d`, `30d`, …) to seconds.
  static int? parseTtlSeconds(String raw) {
    final d = parseTtlDuration(raw);
    return d?.inSeconds;
  }

  static Duration? parseTtlDuration(String raw) {
    final v = raw.trim().toLowerCase();
    return switch (v) {
      '1h' || '60m' => const Duration(hours: 1),
      '1d' || '24h' => const Duration(days: 1),
      '7d' => const Duration(days: 7),
      '30d' => const Duration(days: 30),
      '90d' => const Duration(days: 90),
      '1y' || '365d' => const Duration(days: 365),
      _ => null,
    };
  }

  // ── Node ─────────────────────────────────────────────────────────────────

  Future<String> nodeMode() => _reader.getString('node.mode', 'auto');
  Future<bool> nodeCustomEnabled() => _reader.getBool('node.custom_enabled', false);
  Future<String> nodeCustomAddress() => _reader.getString('node.custom_address', '');
  Future<bool> nodeAllowFallback() => _reader.getBool('node.allow_fallback', true);
  Future<bool> nodeAllowRelays() => _reader.getBool('node.allow_relays', true);
  Future<bool> nodeAllowServiceNodes() => _reader.getBool('node.allow_service_nodes', true);
  Future<bool> nodeMobileData() => _reader.getBool('node.mobile_data', true);
  Future<bool> nodeRoaming() => _reader.getBool('node.roaming', false);
  Future<bool> nodeProxyEnabled() => _reader.getBool('node.proxy_enabled', false);
  Future<String> nodeProxyType() => _reader.getString('node.proxy_type', 'socks5');
  Future<String> nodeProxyAddress() => _reader.getString('node.proxy_address', '');

  Future<String> nodeCertificateFingerprint() async {
    final custom = (await nodeCustomAddress()).trim();
    if (custom.isEmpty) return '—';
    // Stable client-side fingerprint of configured address (no TLS inspect yet).
    final bytes = custom.codeUnits;
    var h = 0;
    for (final b in bytes) {
      h = (h * 31 + b) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  Future<String?> nodeProxyUrl() async {
    if (!await nodeProxyEnabled()) return null;
    final addr = (await nodeProxyAddress()).trim();
    return addr.isEmpty ? null : addr;
  }

  // ── Devices ──────────────────────────────────────────────────────────────

  Future<bool> devicesRequireApproval() =>
      _reader.getBool('devices.require_approval', true);

  Future<List<String>> devicesApprovalMethods() async {
    final saved = await _reader.getStringList('devices.approval_methods');
    if (saved.isNotEmpty) return saved;
    return const ['trusted_device', 'qr'];
  }

  Future<String> devicesHistorySyncDefault() =>
      _reader.getString('devices.history_sync_default', 'from_pairing');

  Future<bool> devicesHiddenAccessDefault() =>
      _reader.getBool('devices.hidden_access_default', false);

  Future<bool> devicesRemoteWipeEnabled() =>
      _reader.getBool('devices.remote_wipe', true);

  // ── Sync / backup / storage ──────────────────────────────────────────────

  Future<bool> syncEnabled() => _reader.getBool('sync.enabled', true);
  Future<String> syncNetwork() => _reader.getString('sync.network', 'any');
  Future<String> syncHistoryDepth() => _reader.getString('sync.history_depth', '30d');

  Future<List<String>> syncTypes() async {
    final saved = await _reader.getStringList('sync.types');
    if (saved.isNotEmpty) return saved;
    return const ['messages', 'contacts', 'settings', 'drafts'];
  }

  /// Whether multi-device message history may be fetched from Home Node.
  Future<bool> messageHistorySyncAllowed() async {
    if (!await syncEnabled()) return false;
    final deviceDefault = await devicesHistorySyncDefault();
    if (deviceDefault == 'none') return false;
    final network = await syncNetwork();
    if (network == 'manual') return false;
    if (network == 'wifi_only' && !_isUnmeteredNetwork()) return false;
    final types = await syncTypes();
    return types.contains('messages');
  }

  /// Max age for history sync on new devices (devices.history_sync_default).
  Future<Duration?> deviceHistorySyncMaxAge() async {
    return switch (await devicesHistorySyncDefault()) {
      'none' => Duration.zero,
      'from_pairing' => await historySyncMaxAge(),
      '30d' => const Duration(days: 30),
      'all' => null,
      _ => await historySyncMaxAge(),
    };
  }

  static bool _isUnmeteredNetwork() {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  /// Oldest message age to pull; `null` = unlimited; `Duration.zero` = none.
  Future<Duration?> historySyncMaxAge() async {
    return switch (await syncHistoryDepth()) {
      'from_now' => Duration.zero,
      '7d' => const Duration(days: 7),
      '30d' => const Duration(days: 30),
      '90d' => const Duration(days: 90),
      'all' => null,
      _ => const Duration(days: 30),
    };
  }

  Future<bool> backupEnabled() => _reader.getBool('backup.enabled', false);
  Future<String> backupSchedule() => _reader.getString('backup.schedule', 'weekly');
  Future<bool> backupEncryption() => _reader.getBool('backup.encryption', true);
  Future<String> backupPassword() => _reader.getString('backup.password', '');

  Future<List<String>> backupContents() async {
    final saved = await _reader.getStringList('backup.contents');
    if (saved.isNotEmpty) return saved;
    return const ['profile', 'settings', 'contacts', 'messages'];
  }

  Future<String> storageMessageLocation() =>
      _reader.getString('storage.message_location', 'device_only');
  Future<String> storageMediaLocation() =>
      _reader.getString('storage.media_location', 'personal_node_s3');
  Future<List<String>> storageMessageNodes() => _lists.load('storage.message_nodes');
  Future<int> storageReplicationFactor() =>
      _reader.getInt('storage.replication_factor', 1);
  Future<String> storageS3Endpoint() => _reader.getString('storage.s3_endpoint', '');
  Future<String> storageS3Bucket() => _reader.getString('storage.s3_bucket', '');
  Future<String> storageS3AccessKey() => _reader.getString('storage.s3_access_key', '');
  Future<String> storageS3SecretKey() => _reader.getString('storage.s3_secret_key', '');
  Future<bool> storageMediaTtlEnabled() =>
      _reader.getBool('storage.media_ttl_enabled', false);
  Future<String> storageMediaTtl() => _reader.getString('storage.media_ttl', '30d');
  Future<String> storageKeyLocation() =>
      _reader.getString('storage.key_location', 'device');
  Future<String> storageBackupLocation() =>
      _reader.getString('storage.backup_location', 'device');
  Future<List<String>> storageAccessDevices() => _lists.load('storage.access_devices');
  Future<List<String>> storageAccessNodes() => _lists.load('storage.access_nodes');

  Future<String?> storageLastSyncIso() async {
    final v = await _reader.getString('storage.last_sync', '');
    return v.isEmpty ? null : v;
  }

  Future<String?> storageLastBackupIso() async {
    final v = await _reader.getString('storage.last_backup', '');
    return v.isEmpty ? null : v;
  }

  Future<void> markLastSync([DateTime? at]) async {
    final iso = (at ?? DateTime.now()).toIso8601String();
    await LocalSettingsStore().setString(
      SettingsCatalogBridge.catalogKey('storage.last_sync'),
      iso,
    );
  }

  Future<void> markLastBackup([DateTime? at]) async {
    final iso = (at ?? DateTime.now()).toIso8601String();
    await LocalSettingsStore().setString(
      SettingsCatalogBridge.catalogKey('storage.last_backup'),
      iso,
    );
  }

  /// Effective media cache max age from storage.media_ttl when enabled.
  Future<Duration?> mediaTtlMaxAge() async {
    if (!await storageMediaTtlEnabled()) return null;
    return parseTtlDuration(await storageMediaTtl());
  }

  Future<String> storageSummaryLabel() async {
    final loc = await storageMessageLocation();
    final media = await storageMediaLocation();
    final nodes = await storageMessageNodes();
    final rf = await storageReplicationFactor();
    final s3 = (await storageS3Endpoint()).trim();
    final parts = <String>[
      switch (loc) {
        'device_only' => 'Сообщения: устройство',
        'personal_node' => 'Сообщения: личная нода',
        'selected_node' => 'Сообщения: выбранная нода',
        _ => 'Сообщения: $loc',
      },
      'Медиа: $media',
    ];
    if (nodes.isNotEmpty) parts.add('Ноды: ${nodes.length}');
    if (rf > 1) parts.add('RF×$rf');
    if (s3.isNotEmpty) parts.add('S3');
    return parts.join(' · ');
  }

  Future<Map<String, String>> storageSummaryDetails() async {
    return {
      'messages': await storageMessageLocation(),
      'media': await storageMediaLocation(),
      'nodes': (await storageMessageNodes()).join(', '),
      'replication': '${await storageReplicationFactor()}',
      's3_endpoint': await storageS3Endpoint(),
      's3_bucket': await storageS3Bucket(),
      'key_location': await storageKeyLocation(),
      'backup_location': await storageBackupLocation(),
      'access_devices': '${(await storageAccessDevices()).length}',
      'access_nodes': '${(await storageAccessNodes()).length}',
      'last_sync': await storageLastSyncIso() ?? '—',
      'last_backup': await storageLastBackupIso() ?? '—',
      'media_ttl': await storageMediaTtlEnabled()
          ? await storageMediaTtl()
          : 'выкл.',
    };
  }

  // ── Calls ────────────────────────────────────────────────────────────────

  Future<bool> callsP2p() => _reader.getBool('calls.p2p', false);
  Future<bool> callsForceRelay() => _reader.getBool('calls.force_relay', true);
  Future<bool> callsVideo() => _reader.getBool('calls.video', true);
  Future<String> callsQuality() => _reader.getString('calls.quality', 'balanced');
  Future<bool> callsNoiseSuppression() => _reader.getBool('calls.noise_suppression', true);
  Future<bool> callsEchoCancellation() => _reader.getBool('calls.echo_cancellation', true);
  Future<bool> callsDataSaver() => _reader.getBool('calls.data_saver', false);

  /// Effective ICE policy: relay-only when force_relay is on or P2P is off.
  Future<bool> callsIceRelayOnly() async {
    if (await callsForceRelay()) return true;
    return !await callsP2p();
  }

  // ── Appearance ───────────────────────────────────────────────────────────

  Future<String> themeMode() => _reader.getString('appearance.theme', 'system');
  Future<String> textSize() => _reader.getString('appearance.text_size', 'normal');
  Future<bool> compactMode() => _reader.getBool('appearance.compact', false);
  Future<bool> animationsEnabled() => _reader.getBool('appearance.animations', true);
  Future<bool> reduceMotion() => _reader.getBool('appearance.reduce_motion', false);
  Future<String> chatBubbles() => _reader.getString('appearance.chat_bubbles', 'bubbles');

  Future<double> textScaleFactor() async => switch (await textSize()) {
        'small' => 0.9,
        'large' => 1.15,
        _ => 1.0,
      };

  Future<bool> developerEnabled() => _reader.getBool('developer.enabled', false);

  /// Keys with real runtime hooks. Keep in sync with settings_impl_status.dart.
  static const wiredIds = {
    'profile.display_name',
    'profile.username_enabled',
    'profile.username',
    'profile.bio',
    'profile.avatar',
    'profile.qr',
    'profile.public_id',
    'profile.language',
    'profile.time_format',
    'profile.date_format',
    'identity.phone_enabled',
    'identity.phone',
    'identity.phone_verified',
    'identity.phone_login',
    'identity.phone_recovery',
    'identity.email_enabled',
    'identity.email',
    'identity.email_verified',
    'identity.email_login',
    'identity.email_recovery',
    'identity.security_notifications',
    'privacy.username_search',
    'privacy.read_receipts',
    'privacy.typing_status',
    'privacy.online_status',
    'privacy.last_seen',
    'privacy.last_seen_list',
    'privacy.invisible_mode',
    'privacy.incoming_messages',
    'privacy.calls_from',
    'privacy.calls_allowlist',
    'privacy.phone_visibility',
    'privacy.phone_visibility_list',
    'privacy.phone_search',
    'privacy.email_visibility',
    'privacy.email_visibility_list',
    'privacy.avatar_visibility',
    'privacy.voice_record_status',
    'privacy.group_invites',
    'privacy.qr_only',
    'privacy.qr_mode',
    'privacy.qr_ttl_minutes',
    'hidden.enabled',
    'hidden.open_method',
    'hidden.pin',
    'hidden.chat_list',
    'hidden.hide_from_search',
    'hidden.hide_notifications',
    'hidden.hide_media',
    'hidden.autolock',
    'contacts.import_enabled',
    'contacts.hash_lookup',
    'contacts.trusted_enabled',
    'contacts.trusted_list',
    'contacts.trust_levels_enabled',
    'contacts.trust_levels',
    'contacts.blocked_list',
    'contacts.key_change_warning',
    'contacts.block_on_key_change',
    'calls.p2p',
    'calls.force_relay',
    'calls.video',
    'calls.quality',
    'calls.noise_suppression',
    'calls.echo_cancellation',
    'calls.data_saver',
    'messages.read_receipts_override',
    'security.pin_enabled',
    'security.pin',
    'security.pin_length',
    'security.alphanumeric_password',
    'security.autolock',
    'security.lock_on_background',
    'security.lock_on_screen_off',
    'security.biometry',
    'security.wipe_enabled',
    'security.wipe_after',
    'security.pin_attempt_policy',
    'security.fake_pin_enabled',
    'security.fake_pin',
    'security.fake_profile_mode',
    'security.fake_profile_chats',
    'security.distress_signal',
    'security.distress_contacts',
    'security.recovery_key',
    'security.recovery_key_enabled',
    'security.require_pin_for_critical',
    'messages.send_key',
    'messages.save_drafts',
    'messages.confirm_delete',
    'messages.confirm_large_files',
    'messages.large_file_mb',
    'messages.auto_delete_enabled',
    'messages.auto_delete_ttl',
    'messages.link_preview',
    'media.autoload_wifi',
    'media.autoload_mobile',
    'media.max_autoload_mb',
    'media.image_quality',
    'media.video_quality',
    'media.cache_limit_gb',
    'media.auto_cleanup',
    'media.auto_cleanup_after',
    'media.save_to_gallery',
    'notifications.enabled',
    'notifications.preview',
    'notifications.types',
    'notifications.dnd_enabled',
    'notifications.dnd_schedule',
    'notifications.dnd_exceptions',
    'notifications.hidden_chat_policy',
    'appearance.theme',
    'appearance.text_size',
    'appearance.compact',
    'appearance.animations',
    'appearance.reduce_motion',
    'appearance.chat_bubbles',
    'node.mode',
    'node.current',
    'node.custom_enabled',
    'node.custom_address',
    'node.certificate_fingerprint',
    'node.allow_fallback',
    'node.allow_relays',
    'node.allow_service_nodes',
    'node.proxy_enabled',
    'node.proxy_type',
    'node.proxy_address',
    'node.mobile_data',
    'node.roaming',
    'sync.enabled',
    'sync.types',
    'sync.network',
    'sync.history_depth',
    'storage.summary',
    'storage.message_location',
    'storage.message_nodes',
    'storage.replication_factor',
    'storage.media_location',
    'storage.s3_endpoint',
    'storage.s3_bucket',
    'storage.s3_access_key',
    'storage.s3_secret_key',
    'storage.media_ttl_enabled',
    'storage.media_ttl',
    'storage.key_location',
    'storage.backup_location',
    'storage.access_devices',
    'storage.access_nodes',
    'storage.last_sync',
    'storage.last_backup',
    'storage.integrity_check',
    'storage.route_audit',
    'storage.delete_local',
    'storage.delete_remote',
    'backup.enabled',
    'backup.schedule',
    'backup.contents',
    'backup.encryption',
    'backup.password',
    'backup.create_now',
    'backup.restore',
    'data.export_profile',
    'data.export_history',
    'data.export_contacts',
    'data.clear_cache',
    'data.clear_local',
    'data.delete_profile',
    'data.revoke_all_devices',
    'devices.current',
    'devices.list',
    'devices.add',
    'devices.require_approval',
    'devices.approval_methods',
    'devices.history_sync_default',
    'devices.hidden_access_default',
    'devices.remote_wipe',
    'developer.enabled',
    'developer.logs',
    'developer.network_debug',
    'developer.test_notifications',
    'developer.test_crypto',
    'developer.protocol_version',
  };
}
