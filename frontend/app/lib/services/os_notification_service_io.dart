import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_navigation_service.dart';

/// OS-level local notifications (macOS / Linux / Windows / mobile).
class OsNotificationService {
  OsNotificationService._();
  static final instance = OsNotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _id = 0;

  bool get isSupported => true;

  String get permission => _ready ? 'granted' : 'default';

  Future<void> init() async {
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const linux = LinuxInitializationSettings(defaultActionName: 'Open');
    const settings = InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
      linux: linux,
    );

    try {
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: (details) {
          final payload = details.payload;
          if (payload != null && payload.isNotEmpty) {
            NotificationNavigationService.instance.openConversation(payload);
          }
        },
      );
      if (Platform.isMacOS || Platform.isIOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true);
        await _plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      }
      _ready = true;
    } catch (e) {
      debugPrint('OsNotificationService.init failed: $e');
    }
  }

  Future<bool> requestPermission() async {
    if (Platform.isMacOS || Platform.isIOS) {
      final mac = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final okMac =
          await mac?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
      final okIos =
          await ios?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
      _ready = okMac || okIos || _ready;
      return _ready;
    }
    _ready = true;
    return true;
  }

  Future<void> show({
    required String title,
    required String body,
    String? conversationId,
  }) async {
    if (!_ready) return;

    final id = ++_id;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'messenger_messages',
        'Сообщения',
        channelDescription: 'Новые сообщения и звонки',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
      linux: LinuxNotificationDetails(),
    );

    try {
      await _plugin.show(id, title, body, details, payload: conversationId);
    } catch (e) {
      debugPrint('OsNotificationService.show failed: $e');
    }
  }
}
