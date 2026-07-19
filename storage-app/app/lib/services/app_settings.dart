// Локальные настройки приложения (allowed_root, порт). Не синхронизируются.
library;

import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static const _keyAllowedRoot = 'allowed_root';
  static const _keyPort = 'port';
  static const _keyOnboarded = 'onboarded';
  static const _keyMinimizeToTray = 'minimize_to_tray';

  final String? allowedRoot;
  final int port;
  final bool onboarded;
  final bool minimizeToTray;

  const AppSettings({
    this.allowedRoot,
    this.port = 7345,
    this.onboarded = false,
    this.minimizeToTray = true,
  });

  bool get isConfigured =>
      onboarded && allowedRoot != null && allowedRoot!.isNotEmpty;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      allowedRoot: prefs.getString(_keyAllowedRoot),
      port: prefs.getInt(_keyPort) ?? 7345,
      onboarded: prefs.getBool(_keyOnboarded) ?? false,
      minimizeToTray: prefs.getBool(_keyMinimizeToTray) ?? true,
    );
  }

  Future<void> save({
    required String allowedRoot,
    int port = 7345,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAllowedRoot, allowedRoot);
    await prefs.setInt(_keyPort, port);
    await prefs.setBool(_keyOnboarded, true);
  }

  Future<void> updatePort(int port) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyPort, port);
  }

  Future<void> updateAllowedRoot(String allowedRoot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAllowedRoot, allowedRoot);
  }

  Future<void> setMinimizeToTray(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyMinimizeToTray, value);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyAllowedRoot);
    await prefs.remove(_keyPort);
    await prefs.remove(_keyOnboarded);
  }
}
