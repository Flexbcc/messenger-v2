import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../models/message.dart';
import '../services/emergency_lock_service.dart';
import '../services/local_settings_store.dart';
import '../services/privacy_preferences_store.dart';
import '../utils/message_format.dart';

final notificationSettingsProvider = ChangeNotifierProvider<NotificationSettings>((ref) => NotificationSettings());

/// Global notification prefs — persisted locally; in-app + OS local notifications.
class NotificationSettings extends ChangeNotifier {
  NotificationSettings({bool loadOnCreate = true}) {
    if (loadOnCreate) {
      _load();
    } else {
      _loaded = true;
    }
  }

  factory NotificationSettings.forTesting() => NotificationSettings(loadOnCreate: false);

  final _store = LocalSettingsStore();
  final _privacy = PrivacyPreferencesStore();

  bool sounds = true;
  bool vibration = true;
  bool inChat = true;
  String preview = 'Полный текст';
  String directChats = 'Все сообщения';
  String groups = 'Все сообщения';
  String privateChats = 'Все сообщения';
  String hiddenChats = 'Выключено';
  String calls = 'Все';
  bool _loaded = false;

  bool _maskFromPrivacy = false;
  bool _hidePreviewsFromPrivacy = false;
  bool _emergencySilenced = false;

  bool get loaded => _loaded;

  Future<void> _load() async {
    sounds = await _store.getBool('notif_sounds', true);
    vibration = await _store.getBool('notif_vibration', true);
    inChat = await _store.getBool('notif_in_chat', true);
    preview = await _store.getString('notif_preview', 'Полный текст');
    directChats = await _store.getString('notif_direct', 'Все сообщения');
    groups = await _store.getString('notif_groups', 'Все сообщения');
    privateChats = await _store.getString('notif_private', 'Все сообщения');
    hiddenChats = await _store.getString('notif_hidden', 'Выключено');
    calls = await _store.getString('notif_calls', 'Все');
    _emergencySilenced = await EmergencyLockService.instance.areNotificationsSilenced();
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

  Future<void> setSounds(bool v) async {
    sounds = v;
    await _store.setBool('notif_sounds', v);
    notifyListeners();
  }

  Future<void> setVibration(bool v) async {
    vibration = v;
    await _store.setBool('notif_vibration', v);
    notifyListeners();
  }

  Future<void> setInChat(bool v) async {
    inChat = v;
    await _store.setBool('notif_in_chat', v);
    notifyListeners();
  }

  Future<void> setPreview(String v) async {
    preview = v;
    await _store.setString('notif_preview', v);
    notifyListeners();
  }

  Future<void> setDirectChats(String v) async {
    directChats = v;
    await _store.setString('notif_direct', v);
    notifyListeners();
  }

  Future<void> setGroups(String v) async {
    groups = v;
    await _store.setString('notif_groups', v);
    notifyListeners();
  }

  Future<void> setPrivateChats(String v) async {
    privateChats = v;
    await _store.setString('notif_private', v);
    notifyListeners();
  }

  Future<void> setHiddenChats(String v) async {
    hiddenChats = v;
    await _store.setString('notif_hidden', v);
    notifyListeners();
  }

  Future<void> setCalls(String v) async {
    calls = v;
    await _store.setString('notif_calls', v);
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
    if (_emergencySilenced) return false;
    if (message.senderUserId == myUserId) return false;
    if (activeConversationId == conversation.id && !inChat) return false;

    if (isHiddenChat) {
      return _channelEnabled(hiddenChats, message, myDisplayName, myUserId, conversation.isGroup);
    }
    if (isPrivateHiddenChat) {
      return _channelEnabled(privateChats, message, myDisplayName, myUserId, conversation.isGroup);
    }
    if (conversation.isGroup) {
      return _channelEnabled(groups, message, myDisplayName, myUserId, true);
    }
    return _channelEnabled(directChats, message, myDisplayName, myUserId, false);
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
      'Только упоминания' => isGroup && _mentionsMe(message.plaintext, myDisplayName, myUserId),
      _ => true,
    };
  }

  bool shouldNotifyIncomingCall({required bool isKnownContact}) {
    if (_emergencySilenced) return false;
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
  }) {
    final mode = effectivePreview;
    return switch (mode) {
      'Скрыто' => isGroup ? 'Новое сообщение в группе' : 'Новое сообщение',
      'Только приложение' => 'Messenger',
      'Только имя отправителя' => senderLabel,
      _ => isGroup ? '$senderLabel: ${messagePreview(message)}' : messagePreview(message),
    };
  }

  static bool _mentionsMe(String? text, String displayName, String userId) {
    if (text == null) return false;
    final lower = text.toLowerCase();
    if (lower.contains('@$userId'.toLowerCase())) return true;
    if (displayName.isNotEmpty && lower.contains('@${displayName.toLowerCase()}')) return true;
    return lower.contains('@');
  }
}
