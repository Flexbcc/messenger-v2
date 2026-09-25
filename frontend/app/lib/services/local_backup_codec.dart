import '../models/message.dart';
import 'local_identity_backup.dart';
import 'media_backup_validation.dart';

/// Pure validation and conversion rules for local backup payloads.
class LocalBackupCodec {
  LocalBackupCodec._();

  static const sensitiveSections = {
    'profile',
    'contacts',
    'messages',
    'conversations',
    'hidden_chats',
    'keys',
  };

  static bool requiresEncryption(Iterable<String> contents) =>
      contents.any(sensitiveSections.contains);

  static const _knownSections = <String>{
    'settings',
    'profile',
    'contacts',
    'messages',
    'conversations',
    'hidden_chats',
    'keys',
    'media',
  };

  /// Checks all bounded and sensitive sections before restore starts writing.
  static void validateRestorePayload(Map<String, dynamic> decoded) {
    if (decoded.length > 32) {
      throw const FormatException('Слишком много секций в копии');
    }
    final meta = decoded['meta'];
    if (meta != null) {
      if (meta is! Map<String, dynamic> || meta['kind'] != 'settings_backup') {
        throw const FormatException('Некорректные метаданные копии');
      }
      final createdAt = meta['created_at'];
      final contents = meta['contents'];
      if (createdAt is! String ||
          createdAt.length > 64 ||
          DateTime.tryParse(createdAt) == null ||
          contents is! List ||
          contents.length > _knownSections.length ||
          contents.any(
            (item) => item is! String || !_knownSections.contains(item),
          )) {
        throw const FormatException('Некорректные метаданные копии');
      }
      final declared = contents.cast<String>().toSet();
      if (declared.length != contents.length ||
          declared.any((section) => !decoded.containsKey(section))) {
        throw const FormatException('Состав копии не совпадает с метаданными');
      }
    }

    final settings = decoded['settings'];
    if (settings != null && settings is! Map<String, dynamic>) {
      throw const FormatException('Некорректная секция настроек');
    }
    _validateProfile(decoded['profile']);
    _validateContacts(decoded['contacts']);
    _validateHiddenChats(decoded['hidden_chats']);
    _validateMessages(
      decoded.containsKey('messages')
          ? decoded['messages']
          : decoded['conversations'],
    );

    final keys = decoded['keys'];
    if (keys != null) {
      if (keys is! Map<String, dynamic>) {
        throw const FormatException('Некорректная секция ключей');
      }
      LocalIdentityBackup.validate(keys);
    }
    final media = decoded['media'];
    if (media != null) {
      if (media is! Map<String, dynamic>) {
        throw const FormatException('Некорректная секция медиа');
      }
      decodeMediaBackup(media);
    }
  }

  static void _validateProfile(Object? raw) {
    if (raw == null) return;
    if (raw is! Map) {
      throw const FormatException('Некорректная секция профиля');
    }
    const limits = <String, int>{
      'user_id': 128,
      'display_name': 120,
      'username': 120,
      'phone': 64,
      'email': 254,
      'bio': 1000,
    };
    if (raw.keys.any((key) => key is! String || !limits.containsKey(key))) {
      throw const FormatException('Некорректная структура профиля');
    }
    for (final entry in limits.entries) {
      final value = raw[entry.key];
      if (value != null && (value is! String || value.length > entry.value)) {
        throw const FormatException('Некорректное поле профиля');
      }
    }
    if (raw['user_id'] is! String ||
        raw['display_name'] is! String ||
        (raw['display_name'] as String).trim().isEmpty) {
      throw const FormatException('В копии отсутствуют данные профиля');
    }
  }

  static void _validateContacts(Object? raw) {
    if (raw == null) return;
    if (raw is! List || raw.length > 500) {
      throw const FormatException('Некорректная секция контактов');
    }
    final ids = <String>{};
    for (final contact in raw) {
      if (contact is! Map ||
          contact.length != 2 ||
          contact['user_id'] is! String ||
          contact['display_name'] is! String) {
        throw const FormatException('Некорректный контакт в копии');
      }
      final id = contact['user_id'] as String;
      final name = contact['display_name'] as String;
      if (!_uuidPattern.hasMatch(id) ||
          !ids.add(id) ||
          name.trim().isEmpty ||
          name.length > 120) {
        throw const FormatException('Некорректный контакт в копии');
      }
    }
  }

  static void _validateHiddenChats(Object? raw) {
    if (raw == null) return;
    if (raw is! List ||
        raw.length > 500 ||
        raw.any((id) => id is! String || id.isEmpty || id.length > 128)) {
      throw const FormatException('Некорректная секция скрытых чатов');
    }
  }

  static void _validateMessages(Object? raw) {
    if (raw == null) return;
    if (raw is! List || raw.length > 200) {
      throw const FormatException('Некорректная секция сообщений');
    }
    final conversationIds = <String>{};
    for (final conversation in raw) {
      if (conversation is! Map ||
          conversation['id'] is! String ||
          conversation['messages'] is! List) {
        throw const FormatException('Некорректная история чата');
      }
      final conversationId = conversation['id'] as String;
      final messages = conversation['messages'] as List;
      if (conversationId.isEmpty ||
          conversationId.length > 128 ||
          !conversationIds.add(conversationId) ||
          messages.length > 200) {
        throw const FormatException('Некорректная история чата');
      }
      final messageIds = <String>{};
      for (final rawMessage in messages) {
        if (rawMessage is! Map) {
          throw const FormatException('Некорректное сообщение в копии');
        }
        final id = rawMessage['id'];
        final sender = rawMessage['sender_user_id'] ?? rawMessage['sender'];
        final at = rawMessage['at'];
        final text = rawMessage['text'];
        if (id is! String ||
            id.isEmpty ||
            id.length > 128 ||
            !messageIds.add(id) ||
            sender is! String ||
            sender.isEmpty ||
            sender.length > 128 ||
            at is! String ||
            at.length > 64 ||
            DateTime.tryParse(at) == null ||
            text is! String ||
            text.length > 1024 * 1024) {
          throw const FormatException('Некорректное сообщение в копии');
        }
        _optionalBoundedString(rawMessage, 'sender_device_id', 128);
        _optionalBoundedString(rawMessage, 'content_type', 64);
        _optionalBoundedString(rawMessage, 'reply_to_message_id', 128);
        _optionalBoundedString(rawMessage, 'reply_preview', 1024);
        _optionalBoundedString(rawMessage, 'system_kind', 64);
        if (rawMessage['is_secret'] != null &&
            rawMessage['is_secret'] is! bool) {
          throw const FormatException('Некорректное сообщение в копии');
        }
        if (rawMessage['duress_code'] != null &&
            rawMessage['duress_code'] is! int) {
          throw const FormatException('Некорректное сообщение в копии');
        }
      }
    }
  }

  static void _optionalBoundedString(
    Map<dynamic, dynamic> value,
    String key,
    int maxLength,
  ) {
    final field = value[key];
    if (field != null && (field is! String || field.length > maxLength)) {
      throw const FormatException('Некорректное сообщение в копии');
    }
  }

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  static void rejectSensitivePlaintext(
    Map<String, dynamic> decoded, {
    required bool wasEncrypted,
  }) {
    if (!wasEncrypted && decoded.keys.any(sensitiveSections.contains)) {
      throw const FormatException(
        'Незашифрованная копия содержит личные данные и не может быть восстановлена',
      );
    }
  }

  static Map<String, dynamic> encodeMessage(ChatMessage message) => {
    'id': message.id,
    'sender_user_id': message.senderUserId,
    'sender_device_id': message.senderDeviceId,
    'at': message.createdAt.toIso8601String(),
    'content_type': message.contentType,
    'text': message.plaintext,
    'reply_to_message_id': message.replyToMessageId,
    'reply_preview': message.replyPreview,
    'is_secret': message.isSecret,
    'system_kind': message.systemKind,
    'duress_code': message.duressCode,
  };

  static Iterable<ChatMessage> decodeMessages(Object? rawConversations) sync* {
    if (rawConversations is! List) return;
    for (final rawConversation in rawConversations.take(200)) {
      if (rawConversation is! Map) continue;
      final conversationId = rawConversation['id'];
      final messages = rawConversation['messages'];
      if (conversationId is! String ||
          conversationId.isEmpty ||
          conversationId.length > 128 ||
          messages is! List) {
        continue;
      }
      for (final raw in messages.take(200)) {
        if (raw is! Map) continue;
        final id = raw['id'];
        final sender = raw['sender_user_id'] ?? raw['sender'];
        final at = raw['at'];
        final text = raw['text'];
        final createdAt = at is String ? DateTime.tryParse(at) : null;
        if (id is! String ||
            id.isEmpty ||
            id.length > 128 ||
            sender is! String ||
            sender.isEmpty ||
            createdAt == null ||
            text is! String ||
            text.length > 1024 * 1024) {
          continue;
        }
        final senderDeviceId = raw['sender_device_id'];
        final contentType = raw['content_type'];
        final replyToMessageId = raw['reply_to_message_id'];
        final replyPreview = raw['reply_preview'];
        final systemKind = raw['system_kind'];
        final duressCode = raw['duress_code'];
        yield ChatMessage(
          id: id,
          conversationId: conversationId,
          senderUserId: sender,
          senderDeviceId: senderDeviceId is String ? senderDeviceId : null,
          ciphertext: '',
          contentType: contentType is String && contentType.length <= 64
              ? contentType
              : 'text',
          cryptoVersion: 'backup-local-v1',
          createdAt: createdAt,
          plaintext: text,
          replyToMessageId: replyToMessageId is String
              ? replyToMessageId
              : null,
          replyPreview: replyPreview is String ? replyPreview : null,
          isSecret: raw['is_secret'] == true,
          systemKind: systemKind is String ? systemKind : null,
          duressCode: duressCode is int ? duressCode : null,
        );
      }
    }
  }

  static String? boundedString(Object? value, {required int maxLength}) {
    if (value is! String || value.length > maxLength) return null;
    return value;
  }
}
