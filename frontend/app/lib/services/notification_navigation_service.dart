import 'dart:async';

/// Opens a conversation when user taps an OS or in-app notification.
class NotificationNavigationService {
  NotificationNavigationService._();
  static final instance = NotificationNavigationService._();

  final _controller = StreamController<String>.broadcast();

  Stream<String> get opens => _controller.stream;

  void openConversation(String conversationId) {
    if (conversationId.isEmpty) return;
    _controller.add(conversationId);
  }

  void dispose() {
    _controller.close();
  }
}
