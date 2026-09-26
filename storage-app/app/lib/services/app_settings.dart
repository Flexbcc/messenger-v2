// Локальные настройки приложения (allowed_root, порт). Не синхронизируются.
library;

import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static const _keyAllowedRoot = 'allowed_root';
  static const _keyPort = 'port';
  static const _keyOnboarded = 'onboarded';
  static const _keyMinimizeToTray = 'minimize_to_tray';
  static const _keyPinHash = 'pairing_pin_hash';
  static const _keyPinSalt = 'pairing_pin_salt';
  static const _keyPinEnabled = 'pairing_pin_enabled';
  static const _keyOpenPairing = 'open_pairing_enabled';

  final String? allowedRoot;
  final int port;
  final bool onboarded;
  final bool minimizeToTray;
  final String? pinHash;
  final String? pinSalt;
  final bool pinEnabled;
  final bool openPairing;

  const AppSettings({
    this.allowedRoot,
    this.port = 7345,
    this.onboarded = false,
    this.minimizeToTray = true,
    this.pinHash,
    this.pinSalt,
    this.pinEnabled = false,
    this.openPairing = false,
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
      pinHash: prefs.getString(_keyPinHash),
      pinSalt: prefs.getString(_keyPinSalt),
      pinEnabled: prefs.getBool(_keyPinEnabled) ?? false,
      openPairing: prefs.getBool(_keyOpenPairing) ?? false,
    );
  }

  Future<void> save({required String allowedRoot, int port = 7345}) async {
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

  Future<void> setPairingPin({
    required String hash,
    required String salt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPinHash, hash);
    await prefs.setString(_keyPinSalt, salt);
    await prefs.setBool(_keyPinEnabled, true);
    await prefs.setBool(_keyOpenPairing, false);
  }

  Future<void> disablePairingPin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyPinEnabled, false);
  }

  Future<void> setOpenPairing(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyOpenPairing, value);
    if (value) await prefs.setBool(_keyPinEnabled, false);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyAllowedRoot);
    await prefs.remove(_keyPort);
    await prefs.remove(_keyOnboarded);
    await prefs.remove(_keyMinimizeToTray);
    await prefs.remove(_keyPinHash);
    await prefs.remove(_keyPinSalt);
    await prefs.remove(_keyPinEnabled);
    await prefs.remove(_keyOpenPairing);
  }
}
