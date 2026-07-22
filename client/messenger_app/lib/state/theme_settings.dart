import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/catalog_sync.dart';
import '../services/local_settings_store.dart';

final themeSettingsProvider = ChangeNotifierProvider<ThemeSettings>((ref) => ThemeSettings());

/// Persists and exposes the user's theme preference (design.md §11 → Оформление).
class ThemeSettings extends ChangeNotifier {
  ThemeSettings() {
    _load();
  }

  final _store = LocalSettingsStore();
  ThemeMode _mode = ThemeMode.system;
  bool _loaded = false;

  ThemeMode get mode => _mode;
  bool get loaded => _loaded;

  Future<void> _load() async {
    final stored = await _store.getString('theme_mode', 'dark');
    _mode = switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    _loaded = true;
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    _mode = mode;
    final name = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await _store.setString('theme_mode', name);
    await CatalogSync.syncTheme();
    notifyListeners();
  }

  String get modeLabel => switch (_mode) {
        ThemeMode.light => 'Светлая',
        ThemeMode.dark => 'Тёмная',
        ThemeMode.system => 'Как в системе',
      };
}
