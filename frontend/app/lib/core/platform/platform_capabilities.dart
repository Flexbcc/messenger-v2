import 'package:flutter/foundation.dart';

/// Platform capability flags for web vs native UX.
class PlatformCapabilities {
  PlatformCapabilities._();

  static bool get isWeb => kIsWeb;

  static bool get biometricsAvailable => !kIsWeb;

  static bool get secureVaultFile => !kIsWeb;

  /// WebRTC getUserMedia on web requires HTTPS (secure context).
  static bool get callsNeedSecureContext => kIsWeb;

  static bool get browserNotificationsAvailable => kIsWeb;

  static String unavailableHint(String feature) =>
      kIsWeb ? '$feature недоступно в веб-версии. Используйте приложение.' : '';

  static String get pwaInstallHint => kIsWeb
      ? 'iOS: «Поделиться» → «На экран Домой». Android: меню → «Установить». '
            'Для установки как приложения нужен HTTPS.'
      : '';
}
