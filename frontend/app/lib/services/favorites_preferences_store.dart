import 'local_settings_store.dart';

class FavoritesPreferencesStore {
  FavoritesPreferencesStore._();
  static final instance = FavoritesPreferencesStore._();

  static const _enabledKey = 'favorites_chat_enabled';
  final _store = LocalSettingsStore();

  Future<bool> isChatEnabled() => _store.getBool(_enabledKey, true);

  Future<void> setChatEnabled(bool value) => _store.setBool(_enabledKey, value);
}
