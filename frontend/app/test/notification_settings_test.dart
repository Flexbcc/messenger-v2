import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/models/conversation.dart';
import 'package:messenger_app/models/message.dart';
import 'package:messenger_app/state/notification_settings.dart';

void main() {
  group('NotificationSettings', () {
    late NotificationSettings settings;

    setUp(() {
      settings = NotificationSettings.forTesting();
      settings.groups = 'Все сообщения';
      settings.calls = 'Все';
      settings.inChat = true;
      settings.preview = 'Полный текст';
    });

    Conversation directConv() => Conversation(
          id: 'c1',
          type: 'direct',
          name: null,
          participantUserIds: ['me', 'other'],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

    Conversation groupConv() => Conversation(
          id: 'g1',
          type: 'group',
          name: 'Team',
          participantUserIds: ['me', 'a', 'b'],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

    ChatMessage textMsg({String? text, String sender = 'other'}) => ChatMessage(
          id: 'm1',
          conversationId: 'c1',
          senderUserId: sender,
          senderDeviceId: null,
          ciphertext: 'x',
          contentType: 'text',
          cryptoVersion: 'signal-v1',
          createdAt: DateTime.now(),
          plaintext: text,
        );

    test('skips own messages', () {
      expect(
        settings.shouldNotifyMessage(
          conversation: directConv(),
          message: textMsg(sender: 'me'),
          activeConversationId: null,
          myUserId: 'me',
          myDisplayName: 'Me',
          isKnownContact: true,
        ),
        isFalse,
      );
    });

    test('respects in-chat suppression', () {
      settings.inChat = false;
      expect(
        settings.shouldNotifyMessage(
          conversation: directConv(),
          message: textMsg(text: 'hi'),
          activeConversationId: 'c1',
          myUserId: 'me',
          myDisplayName: 'Me',
          isKnownContact: true,
        ),
        isFalse,
      );
    });

    test('group notifications off', () {
      settings.groups = 'Выключено';
      expect(
        settings.shouldNotifyMessage(
          conversation: groupConv(),
          message: textMsg(text: 'hello'),
          activeConversationId: null,
          myUserId: 'me',
          myDisplayName: 'Me',
          isKnownContact: true,
        ),
        isFalse,
      );
    });

    test('group mentions only', () {
      settings.groups = 'Только упоминания';
      expect(
        settings.shouldNotifyMessage(
          conversation: groupConv(),
          message: textMsg(text: 'hello everyone'),
          activeConversationId: null,
          myUserId: 'me',
          myDisplayName: 'Alice',
          isKnownContact: true,
        ),
        isFalse,
      );
      expect(
        settings.shouldNotifyMessage(
          conversation: groupConv(),
          message: textMsg(text: '@Alice check this'),
          activeConversationId: null,
          myUserId: 'me',
          myDisplayName: 'Alice',
          isKnownContact: true,
        ),
        isTrue,
      );
    });

    test('call notifications for contacts only', () {
      settings.calls = 'Только контакты';
      expect(settings.shouldNotifyIncomingCall(isKnownContact: false), isFalse);
      expect(settings.shouldNotifyIncomingCall(isKnownContact: true), isTrue);
    });

    test('preview modes', () {
      settings.preview = 'Скрыто';
      final body = settings.bodyForMessage(
        message: textMsg(text: 'secret'),
        senderLabel: 'Bob',
        isGroup: false,
      );
      expect(body, 'Новое сообщение');
    });
  });
}
