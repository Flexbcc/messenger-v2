/// Which catalog settings actually affect app runtime vs UI-only (spec filler).
///
/// Keep this list honest: only IDs with real call sites / bridges.
/// Spec has ~184 entries; most persist locally but do not drive product behavior yet.
///
class SettingsImplStatus {
  SettingsImplStatus._();

  static bool isVerified(String id) => _verifiedIds.contains(id);

  static bool isLive(String id) => SettingsRuntimeWiring.covers(id);

  static bool isStub(String id) => !isLive(id);

  static bool isWiredUnverified(String id) => isLive(id) && !isVerified(id);

  static int stubCount(Iterable<String> ids) => ids.where(isStub).length;

  static int liveCount(Iterable<String> ids) => ids.where(isLive).length;

  static int verifiedCount(Iterable<String> ids) =>
      ids.where(isVerified).length;

  static int wiredUnverifiedCount(Iterable<String> ids) =>
      ids.where(isWiredUnverified).length;

  /// Obsolete settings from the original distributed-node specification.
  ///
  /// They are intentionally absent from the PWA: a browser cannot configure
  /// its network proxy, S3 credentials or server-side replication, and the
  /// current product uses one Home Node plus local encrypted recovery.
  static const retiredIds = {
    'identity.security_notifications',
    'privacy.voice_record_status',
    'node.mode',
    'node.proxy_enabled',
    'node.proxy_type',
    'node.proxy_address',
    'sync.types',
    'sync.network',
    'storage.message_location',
    'storage.message_nodes',
    'storage.replication_factor',
    'storage.s3_endpoint',
    'storage.s3_bucket',
    'storage.s3_access_key',
    'storage.s3_secret_key',
    'storage.key_location',
    'storage.access_nodes',
    'storage.delete_remote',
    'backup.schedule',
  };

  /// Strictly audited in the current sequential settings pass.
  static const _verifiedIds = {
    'appearance.theme',
    'appearance.text_size',
    'appearance.compact',
    'appearance.animations',
    'appearance.reduce_motion',
    'appearance.chat_bubbles',
    'notifications.enabled',
    'notifications.preview',
    'notifications.types',
    'notifications.dnd_enabled',
    'notifications.dnd_schedule',
    'notifications.dnd_exceptions',
    'notifications.hidden_chat_policy',
    'messages.send_key',
    'messages.save_drafts',
    'messages.confirm_delete',
    'messages.confirm_large_files',
    'messages.large_file_mb',
    'messages.read_receipts_override',
    'messages.auto_delete_enabled',
    'messages.auto_delete_ttl',
    'messages.link_preview',
    'privacy.last_seen',
    'privacy.last_seen_list',
    'privacy.online_status',
    'privacy.read_receipts',
    'privacy.typing_status',
    'privacy.invisible_mode',
    'backup.enabled',
    'backup.contents',
    'backup.encryption',
    'backup.password',
    'backup.create_now',
    'backup.restore',
    'data.keep_local_on_logout',
    'security.pin_enabled',
    'security.pin',
    'security.pin_length',
    'security.alphanumeric_password',
    'security.autolock',
    'security.lock_on_background',
    'security.lock_on_screen_off',
    'security.pin_attempt_policy',
    'security.wipe_enabled',
    'security.wipe_after',
    'security.fake_pin_enabled',
    'security.fake_pin',
    'security.fake_profile_chats',
    'security.distress_signal',
    'security.distress_contacts',
    'security.require_pin_for_critical',
    'hidden.enabled',
    'hidden.open_method',
    'hidden.chat_list',
    'hidden.hide_from_search',
    'hidden.hide_notifications',
    'hidden.hide_media',
    'hidden.autolock',
    'contacts.trusted_enabled',
    'contacts.trusted_list',
    'contacts.trust_levels_enabled',
    'contacts.trust_levels',
    'contacts.blocked_list',
    'contacts.key_change_warning',
    'contacts.block_on_key_change',
    'devices.current',
    'devices.list',
    'devices.require_approval',
    'devices.history_sync_default',
    'devices.hidden_access_default',
    'devices.remote_wipe',
    'media.autoload_wifi',
    'media.autoload_mobile',
    'media.max_autoload_mb',
    'media.image_quality',
    'media.cache_limit_gb',
    'media.auto_cleanup',
    'media.auto_cleanup_after',
    'sync.enabled',
    'sync.history_depth',
    'storage.media_ttl_enabled',
    'storage.media_ttl',
    'storage.backup_location',
    'storage.access_devices',
    'data.delete_profile',
  };
}

abstract final class SettingsRuntimeWiring {
  static bool covers(String id) =>
      _SettingsRuntimeWiringIds.all.contains(id) &&
      !_knownNonFunctionalIds.contains(id);

  /// Values that may persist or have a getter, but do not currently complete
  /// the user-visible contract promised by the setting.
  ///
  /// Keep this list conservative. A setting leaves it only with a real
  /// consumer/action and a scenario test.
  static const _knownNonFunctionalIds = <String>{};
}

/// True live set — bridge + UI consumers. Expand only when wiring lands.
/// Must stay in sync with [SettingsRuntime.wiredIds].
abstract final class _SettingsRuntimeWiringIds {
  static const all = {
    // Profile / identity (API sync + locale / timestamps)
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
    'identity.email_enabled',
    'identity.email',
    'identity.security_notifications',
    'data.keep_local_on_logout',
    // Privacy (wired into messaging / presence / calls / share)
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
    'hidden.chat_list',
    'hidden.hide_from_search',
    'hidden.hide_notifications',
    'hidden.hide_media',
    'hidden.autolock',
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
    // Security / lock (PIN bridge)
    'security.pin_enabled',
    'security.pin',
    'security.pin_length',
    'security.alphanumeric_password',
    'security.autolock',
    'security.lock_on_background',
    'security.lock_on_screen_off',
    'security.wipe_enabled',
    'security.wipe_after',
    'security.pin_attempt_policy',
    'security.fake_pin_enabled',
    'security.fake_pin',
    'security.fake_profile_chats',
    'security.distress_signal',
    'security.distress_contacts',
    'security.require_pin_for_critical',
    // Messages (wired)
    'messages.send_key',
    'messages.save_drafts',
    'messages.confirm_delete',
    'messages.confirm_large_files',
    'messages.large_file_mb',
    'messages.auto_delete_enabled',
    'messages.auto_delete_ttl',
    'messages.link_preview',
    // Media (DataStorage + size cap + quality/cache)
    'media.autoload_wifi',
    'media.autoload_mobile',
    'media.max_autoload_mb',
    'media.image_quality',
    'media.cache_limit_gb',
    'media.auto_cleanup',
    'media.auto_cleanup_after',
    // Notifications (bridge + DND / type filters)
    'notifications.enabled',
    'notifications.preview',
    'notifications.types',
    'notifications.dnd_enabled',
    'notifications.dnd_schedule',
    'notifications.dnd_exceptions',
    'notifications.hidden_chat_policy',
    // Appearance (theme via ThemeSettings sync; text/compact/animations/bubbles live)
    'appearance.theme',
    'appearance.text_size',
    'appearance.compact',
    'appearance.animations',
    'appearance.reduce_motion',
    'appearance.chat_bubbles',
    // Node / sync / storage
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
    // Backup / data actions
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
    // Devices
    'devices.current',
    'devices.list',
    'devices.require_approval',
    'devices.history_sync_default',
    'devices.hidden_access_default',
    'devices.remote_wipe',
    // Developer
    'developer.enabled',
    'developer.logs',
    'developer.network_debug',
    'developer.test_notifications',
    'developer.test_crypto',
    'developer.protocol_version',
  };
}
