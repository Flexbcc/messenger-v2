import 'local_settings_store.dart';

/// Local prefs for secret chat session (client-only).
class SecretChatPreferencesStore {
  SecretChatPreferencesStore._();
  static final instance = SecretChatPreferencesStore._();

  final _store = LocalSettingsStore();

  /// In-chat idle timeout before secret mode ends: 1, 2, 3, or 5 minutes.
  Future<int> sessionTimeoutMinutes() async {
    final v = await _store.getInt('secret_chat_timeout_min', 3);
    return switch (v) {
      1 || 2 || 3 || 5 => v,
      _ => 3,
    };
  }

  Future<void> setSessionTimeoutMinutes(int minutes) async {
    final v = switch (minutes) {
      1 || 2 || 3 || 5 => minutes,
      _ => 3,
    };
    await _store.setInt('secret_chat_timeout_min', v);
  }

  /// Optional TTL for secret messages (seconds). Null = off.
  Future<int?> secretDisappearingSeconds() async {
    final v = await _store.getInt('secret_chat_disappear_sec', 0);
    if (v <= 0) return null;
    return v;
  }

  Future<void> setSecretDisappearingSeconds(int? seconds) async {
    await _store.setInt('secret_chat_disappear_sec', seconds ?? 0);
  }

  static const disappearingOptions = <(String, int?)>[
    ('Выкл', null),
    ('1 мин', 60),
    ('5 мин', 300),
    ('1 час', 3600),
    ('24 часа', 86400),
  ];
}
