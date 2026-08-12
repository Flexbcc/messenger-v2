import 'dart:async';

/// Opens a conversation when user taps an OS or in-app notification.
class NotificationNavigationService {
  NotificationNavigationService._();
  static final instance = NotificationNavigationService._();

  final _controller = StreamController<String>.broadcast();
  final _loginApprovalController = StreamController<void>.broadcast();

  Stream<String> get opens => _controller.stream;
  Stream<void> get loginApprovalOpens => _loginApprovalController.stream;

  void openConversation(String conversationId) {
    if (conversationId.isEmpty) return;
    _controller.add(conversationId);
  }

  void openLoginApproval() => _loginApprovalController.add(null);

  void dispose() {
    _controller.close();
    _loginApprovalController.close();
  }
}
