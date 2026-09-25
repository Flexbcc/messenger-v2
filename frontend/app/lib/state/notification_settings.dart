import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../models/message.dart';
import '../services/catalog_list_store.dart';
import '../services/catalog_sync.dart';
import '../services/emergency_lock_service.dart';
import '../services/local_settings_store.dart';
import '../services/privacy_preferences_store.dart';
import '../services/settings_catalog_bridge.dart';
import '../utils/message_format.dart';

final notificationSettingsProvider =
    ChangeNotifierProvider<NotificationSettings>(
      (ref) => NotificationSettings(),
    );

/// Global notification prefs — persisted locally; in-app + OS local notifications.
class NotificationSettings extends ChangeNotifier {
  NotificationSettings({bool loadOnCreate = true}) {
    if (loadOnCreate) {
      _load();
    } else {
      _loaded = true;
    }
  }

  factory NotificationSettings.forTesting() =>
      NotificationSettings(loadOnCreate: false);

  final _store = LocalSettingsStore();
  final _privacy = PrivacyPreferencesStore();
  final _lists = CatalogListStore();

  bool sounds = true;
  bool vibration = true;
  bool inChat = true;
  bool enabled = true;
  String preview = 'Полный текст';
  String directChats = 'Все сообщения';
  String groups = 'Все сообщения';
  String privateChats = 'Все сообщения';
  String hiddenChats = 'Выключено';
  String calls = 'Все';

  /// Catalog [notifications.types] multi-select.
  List<String> enabledTypes = const [
    'direct',
    'mentions',
    'replies',
    'calls',
    'security',
  ];

  bool dndEnabled = false;
  List<String> dndSchedule = const [];
  List<String> dndExceptions = const [];

  /// Catalog [notifications.hidden_chat_policy]: none | generic | normal.
  String hiddenChatPolicy = 'none';

  bool _loaded = false;

  bool _maskFromPrivacy = false;
  bool _hidePreviewsFromPrivacy = false;
  bool _emergencySilenced = false;

  bool get loaded => _loaded;

  /// Reload from SharedPreferences (after catalog bridge sync).
  Future<void> reloadFromStore() => _load();

  Future<void> _load() async {
    final enabled = await _store.getBool('notif_enabled', true);
    this.enabled = enabled;
    sounds = await _store.getBool('notif_sounds', true);
    vibration = await _store.getBool('notif_vibration', true);
    inChat = await _store.getBool('notif_in_chat', true);
    preview = await _store.getString('notif_preview', 'Полный текст');
    directChats = await _store.getString('notif_direct', 'Все сообщения');
    groups = await _store.getString('notif_groups', 'Все сообщения');
    privateChats = await _store.getString('notif_private', 'Все сообщения');
    hiddenChats = await _store.getString('notif_hidden', 'Выключено');
    calls = await _store.getString('notif_calls', 'Все');

    enabledTypes = await _store.getStringList(
      SettingsCatalogBridge.catalogKey('notifications.types'),
    );
    if (enabledTypes.isEmpty) {
      enabledTypes = const [
        'direct',
        'mentions',
        'replies',
        'calls',
        'security',
      ];
    }

    dndEnabled = await _store.getBool(
      SettingsCatalogBridge.catalogKey('notifications.dnd_enabled'),
      false,
    );
    dndSchedule = await _lists.load('notifications.dnd_schedule');
    dndExceptions = await _lists.load('notifications.dnd_exceptions');
    hiddenChatPolicy = await _store.getString(
      SettingsCatalogBridge.catalogKey('notifications.hidden_chat_policy'),
      'none',
    );

    _emergencySilenced = await EmergencyLockService.instance
        .areNotificationsSilenced();
    await refreshPrivacyOverrides();
    _loaded = true;
    notifyListeners();
  }

  Future<void> refreshPrivacyOverrides() async {
    _maskFromPrivacy = await _privacy.maskNotifications();
    _hidePreviewsFromPrivacy = await _privacy.hidePreviews();
    notifyListeners();
  }

  String get effectivePreview {
    if (_maskFromPrivacy || _hidePreviewsFromPrivacy) return 'Скрыто';
    return preview;
  }

  Future<void> _syncCatalog() => CatalogSync.syncNotifications();

  Future<void> setEnabled(bool v) async {
    enabled = v;
    await _store.setBool('notif_enabled', v);
    await _syncCatalog();
    notifyListeners();
  }

  Future<void> setSounds(bool v) async {
    sounds = v;
    await _store.setBool('notif_sounds', v);
    await _syncCatalog();
    notifyListeners();
  }

  Future<void> setVibration(bool v) async {
    vibration = v;
    await _store.setBool('notif_vibration', v);
    await _syncCatalog();
    notifyListeners();
  }

  Future<void> setInChat(bool v) async {
    inChat = v;
    await _store.setBool('notif_in_chat', v);
    await _syncCatalog();
    notifyListeners();
  }

  Future<void> setPreview(String v) async {
    preview = v;
    await _store.setString('notif_preview', v);
    await _syncCatalog();
    notifyListeners();
  }

  Future<void> setDirectChats(String v) async {
    directChats = v;
    await _store.setString('notif_direct', v);
    await _syncCatalog();
    notifyListeners();
  }

  Future<void> setGroups(String v) async {
    groups = v;
    await _store.setString('notif_groups', v);
    await _syncCatalog();
    notifyListeners();
  }

  Future<void> setPrivateChats(String v) async {
    privateChats = v;
    await _store.setString('notif_private', v);
    await _syncCatalog();
    notifyListeners();
  }

  Future<void> setHiddenChats(String v) async {
    hiddenChats = v;
    await _store.setString('notif_hidden', v);
    await _syncCatalog();
    notifyListeners();
  }

  Future<void> setCalls(String v) async {
    calls = v;
    await _store.setString('notif_calls', v);
    await _syncCatalog();
    notifyListeners();
  }

  Future<void> silenceAllForEmergency() async {
    sounds = false;
    vibration = false;
    inChat = false;
    preview = 'Скрыто';
    directChats = 'Выключено';
    groups = 'Выключено';
    privateChats = 'Выключено';
    hiddenChats = 'Выключено';
    calls = 'Выключено';
    _emergencySilenced = true;
    await _store.setBool('notif_sounds', false);
    await _store.setBool('notif_vibration', false);
    await _store.setBool('notif_in_chat', false);
    await _store.setString('notif_preview', 'Скрыто');
    await _store.setString('notif_direct', 'Выключено');
    await _store.setString('notif_groups', 'Выключено');
    await _store.setString('notif_private', 'Выключено');
    await _store.setString('notif_hidden', 'Выключено');
    await _store.setString('notif_calls', 'Выключено');
    await EmergencyLockService.instance.setNotificationsSilenced(true);
    notifyListeners();
  }

  bool shouldNotifyMessage({
    required Conversation conversation,
    required ChatMessage message,
    required String? activeConversationId,
    required String myUserId,
    required String myDisplayName,
    required bool isKnownContact,
    bool isHiddenChat = false,
    bool isPrivateHiddenChat = false,
  }) {
    if (!enabled || _emergencySilenced) return false;
    if (message.senderUserId == myUserId) return false;
    if (activeConversationId == conversation.id && !inChat) return false;

    if (_isInDndWindow() &&
        !_isDndException(conversation, message.senderUserId)) {
      return false;
    }

    if (isHiddenChat) {
      return switch (hiddenChatPolicy) {
        'none' => false,
        'generic' => true,
        'normal' => _channelEnabled(
          hiddenChats == 'Выключено' ? 'Все сообщения' : hiddenChats,
          message,
          myDisplayName,
          myUserId,
          conversation.isGroup,
        ),
        _ => _channelEnabled(
          hiddenChats,
          message,
          myDisplayName,
          myUserId,
          conversation.isGroup,
        ),
      };
    }

    if (!_typeAllowed(conversation, message, myDisplayName, myUserId)) {
      return false;
    }

    if (isPrivateHiddenChat) {
      return _channelEnabled(
        privateChats,
        message,
        myDisplayName,
        myUserId,
        conversation.isGroup,
      );
    }
    if (conversation.isGroup) {
      return _channelEnabled(groups, message, myDisplayName, myUserId, true);
    }
    return _channelEnabled(
      directChats,
      message,
      myDisplayName,
      myUserId,
      false,
    );
  }

  bool _typeAllowed(
    Conversation conversation,
    ChatMessage message,
    String myDisplayName,
    String myUserId,
  ) {
    final types = enabledTypes;
    if (conversation.isGroup) {
      if (types.contains('groups')) return true;
      final mentionsMe = _mentionsMe(
        message.plaintext,
        myDisplayName,
        myUserId,
      );
      if (mentionsMe && types.contains('mentions')) return true;
      if (message.replyToMessageId != null && types.contains('replies')) {
        return true;
      }
      return false;
    }
    return types.contains('direct');
  }

  bool _isInDndWindow({DateTime? now}) {
    if (!dndEnabled) return false;
    if (dndSchedule.isEmpty) {
      return true; // enabled with no ranges = always quiet
    }
    final t = now ?? DateTime.now();
    final minutes = t.hour * 60 + t.minute;
    for (final raw in dndSchedule) {
      final range = _parseTimeRange(raw);
      if (range == null) continue;
      final (start, end) = range;
      if (start == end) return true;
      if (start < end) {
        if (minutes >= start && minutes < end) return true;
      } else {
        // Overnight window, e.g. 22:00–08:00
        if (minutes >= start || minutes < end) return true;
      }
    }
    return false;
  }

  bool _isDndException(Conversation conversation, String senderUserId) {
    if (dndExceptions.isEmpty) return false;
    return dndExceptions.contains(conversation.id) ||
        dndExceptions.contains(senderUserId) ||
        conversation.participantUserIds.any(dndExceptions.contains);
  }

  /// Parses `HH:MM-HH:MM` / `HH:MM – HH:MM` into minute-of-day bounds.
  static (int, int)? _parseTimeRange(String raw) {
    final cleaned = raw.trim().replaceAll('–', '-').replaceAll('—', '-');
    final parts = cleaned.split(RegExp(r'\s*-\s*'));
    if (parts.length != 2) return null;
    final start = _parseHm(parts[0]);
    final end = _parseHm(parts[1]);
    if (start == null || end == null) return null;
    return (start, end);
  }

  static int? _parseHm(String raw) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(raw.trim());
    if (m == null) return null;
    final h = int.tryParse(m.group(1)!);
    final min = int.tryParse(m.group(2)!);
    if (h == null || min == null || h > 23 || min > 59) return null;
    return h * 60 + min;
  }

  bool _channelEnabled(
    String policy,
    ChatMessage message,
    String myDisplayName,
    String myUserId,
    bool isGroup,
  ) {
    return switch (policy) {
      'Выключено' => false,
      'Только упоминания' =>
        isGroup && _mentionsMe(message.plaintext, myDisplayName, myUserId),
      _ => true,
    };
  }

  bool shouldNotifyIncomingCall({required bool isKnownContact}) {
    if (_emergencySilenced) return false;
    if (!enabledTypes.contains('calls')) return false;
    if (_isInDndWindow() && dndExceptions.isEmpty) return false;
    return switch (calls) {
      'Выключено' => false,
      'Только контакты' => isKnownContact,
      _ => true,
    };
  }

  String titleForSender(String senderLabel) => senderLabel;

  String bodyForMessage({
    required ChatMessage message,
    required String senderLabel,
    required bool isGroup,
    bool forceGeneric = false,
  }) {
    if (forceGeneric) {
      return isGroup ? 'Новое сообщение в группе' : 'Новое сообщение';
    }
    final mode = effectivePreview;
    return switch (mode) {
      'Скрыто' => isGroup ? 'Новое сообщение в группе' : 'Новое сообщение',
      'Только приложение' => 'Messenger',
      'Только имя отправителя' => senderLabel,
      _ =>
        isGroup
            ? '$senderLabel: ${messagePreview(message)}'
            : messagePreview(message),
    };
  }

  static bool _mentionsMe(String? text, String displayName, String userId) {
    if (text == null) return false;
    final lower = text.toLowerCase();
    if (lower.contains('@$userId'.toLowerCase())) return true;
    if (displayName.isNotEmpty &&
        lower.contains('@${displayName.toLowerCase()}')) {
      return true;
    }
    return lower.contains('@');
  }

  @visibleForTesting
  bool debugIsInDndWindow(DateTime now) => _isInDndWindow(now: now);
}
