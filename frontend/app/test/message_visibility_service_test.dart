import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/models/message.dart';
import 'package:messenger_app/services/message_visibility_service.dart';

ChatMessage _message({
  required String id,
  required DateTime createdAt,
  int? ttlSeconds,
  bool secret = false,
  String contentType = 'text',
}) => ChatMessage(
  id: id,
  conversationId: 'conversation-1',
  senderUserId: 'alice',
  senderDeviceId: 'alice-device',
  ciphertext: 'opaque',
  contentType: contentType,
  cryptoVersion: 'signal-v1',
  createdAt: createdAt,
  plaintext: id,
  ttlSeconds: ttlSeconds,
  isSecret: secret,
);

void main() {
  const service = MessageVisibilityService();
  final createdAt = DateTime.utc(2026, 9, 24, 12);

  List<ChatMessage> visibleAt(Iterable<ChatMessage> messages, DateTime now) =>
      service.visible(
        messages: messages,
        locallyHiddenMessageIds: const {},
        secretSessionActive: true,
        disappearingSeconds: null,
        secretDisappearingSeconds: null,
        now: now,
      );

  test('per-message TTL is visible before expiry and hidden at expiry', () {
    final message = _message(
      id: 'ttl-message',
      createdAt: createdAt,
      ttlSeconds: 60,
    );

    expect(visibleAt([message], createdAt.add(const Duration(seconds: 59))), [
      message,
    ]);
    expect(
      visibleAt([message], createdAt.add(const Duration(seconds: 60))),
      isEmpty,
    );
    expect(
      service.nextExpiry(
        messages: [message],
        locallyHiddenMessageIds: const {},
        secretSessionActive: true,
        disappearingSeconds: null,
        secretDisappearingSeconds: null,
        now: createdAt,
      ),
      createdAt.add(const Duration(seconds: 60)),
    );
  });

  test('expired messages stay hidden when a closed chat is opened later', () {
    final expired = _message(
      id: 'expired-while-closed',
      createdAt: createdAt,
      ttlSeconds: 30,
    );
    final permanent = _message(id: 'permanent', createdAt: createdAt);

    final reopenedAt = createdAt.add(const Duration(hours: 3));
    expect(visibleAt([expired, permanent], reopenedAt), [permanent]);
  });

  test('conversation and secret-session timers apply independently', () {
    final ordinary = _message(id: 'ordinary', createdAt: createdAt);
    final secret = _message(id: 'secret', createdAt: createdAt, secret: true);
    final evaluatedAt = createdAt.add(const Duration(seconds: 90));

    final visible = service.visible(
      messages: [ordinary, secret],
      locallyHiddenMessageIds: const {},
      secretSessionActive: true,
      disappearingSeconds: 60,
      secretDisappearingSeconds: 120,
      now: evaluatedAt,
    );

    expect(visible, [secret]);
  });
}
