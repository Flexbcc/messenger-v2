/// Push token registration service (Task #17).
///
/// Отвечает за:
/// 1. Получение FCM/APNs токена от платформы (firebase_messaging / flutter_apns)
/// 2. Регистрацию токена на push-proxy при каждом логине
/// 3. Удаление токена при logout
///
/// Privacy принцип: push payload от сервера содержит только тип события.
/// Клиент после wakeup подключается через WS и получает реальные данные через E2EE.
///
/// MVP NOTE: firebase_messaging пакет намеренно НЕ добавлен в pubspec.yaml —
/// он требует google-services.json и ломает сборку без Firebase проекта.
/// Этот сервис построен с абстракцией чтобы легко подключить FCM/APNs позже.
/// Для локальных уведомлений (foreground) используем flutter_local_notifications.
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'api_client.dart';

class PushTokenService {
  PushTokenService._();
  static final instance = PushTokenService._();

  static const _tokenPrefsKey = 'push_token';
  static const _platformPrefsKey = 'push_platform';

  final _localNotifications = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Инициализация локальных уведомлений (работает без FCM/APNs).
  /// Вызывается при старте приложения.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _localNotifications.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );
  }

  void _onNotificationTapped(NotificationResponse response) {
    // Handled by AppController via Navigator — payload содержит call_id
    // TODO: deep link в экран входящего звонка
  }

  /// Показывает локальное уведомление о входящем звонке.
  /// Используется когда приложение в foreground (WS активен).
  Future<void> showIncomingCallNotification({
    required String callerName,
    required String callId,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'incoming_calls',
      'Входящие звонки',
      channelDescription: 'Уведомления о входящих звонках',
      importance: Importance.max,
      priority: Priority.high,
      fullScreenIntent: true,
      category: AndroidNotificationCategory.call,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
    );
    await _localNotifications.show(
      callId.hashCode,
      'Входящий звонок',
      callerName,
      const NotificationDetails(android: androidDetails, iOS: iosDetails),
      payload: callId,
    );
  }

  /// Отменяет уведомление о звонке (когда звонок отклонён/принят/завершён).
  Future<void> cancelCallNotification(String callId) async {
    await _localNotifications.cancel(callId.hashCode);
  }

  /// Регистрирует push token на push-proxy.
  /// Вызывается после логина. Token получается из FCM/APNs (если доступны).
  Future<void> registerToken(ApiClient api, String deviceId) async {
    final token = await _getPlatformToken();
    if (token == null) return;   // FCM/APNs не настроены — skip

    final platform = Platform.isIOS ? 'apns' : 'fcm';

    try {
      await api.registerPushToken(
        deviceId: deviceId,
        platform: platform,
        token: token,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenPrefsKey, token);
      await prefs.setString(_platformPrefsKey, platform);
    } catch (e) {
      // Non-fatal — push уведомления недоступны, но приложение работает
    }
  }

  /// Удаляет токен при logout.
  Future<void> unregisterToken(ApiClient api, String deviceId) async {
    try {
      await api.deletePushToken(deviceId: deviceId);
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenPrefsKey);
    await prefs.remove(_platformPrefsKey);
  }

  /// Получает платформенный push token.
  /// MVP: возвращает null если FCM/APNs не настроены.
  /// Production: здесь подключается firebase_messaging или flutter_apns.
  Future<String?> _getPlatformToken() async {
    // MVP stub — в production заменить на:
    // Android: FirebaseMessaging.instance.getToken()
    // iOS: await FlutterApns.instance.requestPermission() + getDeviceToken()
    //
    // Читаем кешированный токен если был зарегистрирован при предыдущем запуске
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenPrefsKey);
  }
}
