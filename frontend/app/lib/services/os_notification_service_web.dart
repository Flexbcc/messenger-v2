// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import 'notification_navigation_service.dart';

/// Browser Notification API (PWA / tab in background).
class OsNotificationService {
  OsNotificationService._();
  static final instance = OsNotificationService._();

  bool _ready = false;

  bool get isSupported => html.Notification.supported;

  String get permission => html.Notification.permission ?? 'default';

  Future<void> init() async {
    _ready = html.Notification.supported && permission == 'granted';
  }

  /// Call from Settings → Уведомления on web (requires user gesture).
  Future<bool> requestPermission() async {
    if (!html.Notification.supported) return false;
    final result = await html.Notification.requestPermission();
    _ready = result == 'granted';
    return _ready;
  }

  Future<void> show({
    required String title,
    required String body,
    String? conversationId,
  }) async {
    if (!html.Notification.supported) return;
    if (permission != 'granted') return;
    // The visible app already renders its own in-app banner. Showing a system
    // notification as well produces a duplicate for every incoming message.
    if (html.document.visibilityState == 'visible') return;
    try {
      final notification = html.Notification(title, body: body);
      notification.onClick.first.then((_) {
        notification.close();
        if (conversationId != null) {
          NotificationNavigationService.instance.openConversation(
            conversationId,
          );
        }
      });
    } catch (_) {
      // Non-fatal — e.g. blocked by browser policy.
    }
  }
}
