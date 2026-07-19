import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Events raised when the app should show an in-app notification banner.
class InAppNotificationEvent {
  InAppNotificationEvent({
    required this.title,
    required this.body,
    this.playSound = true,
    this.vibrate = true,
    this.conversationId,
  });

  final String title;
  final String body;
  final bool playSound;
  final bool vibrate;
  final String? conversationId;
}

/// Lightweight bus — AppController publishes, UI layer subscribes.
class InAppNotificationService {
  InAppNotificationService._();
  static final instance = InAppNotificationService._();

  final _controller = StreamController<InAppNotificationEvent>.broadcast();

  Stream<InAppNotificationEvent> get stream => _controller.stream;

  void notify(InAppNotificationEvent event) {
    if (event.playSound) _playSound();
    if (event.vibrate) _vibrate();
    _controller.add(event);
  }

  void _playSound() {
    try {
      SystemSound.play(SystemSoundType.click);
    } catch (_) {
      // Web/desktop may not support system sounds — non-fatal.
    }
  }

  void _vibrate() {
    if (kIsWeb) return;
    try {
      HapticFeedback.mediumImpact();
    } catch (_) {}
  }

  void dispose() {
    _controller.close();
  }
}
