import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_settings_store.dart';

final themeSettingsProvider = ChangeNotifierProvider<ThemeSettings>((ref) => ThemeSettings());

/// Persists theme + text scale (design.md §11 → Оформление).
class ThemeSettings extends ChangeNotifier {
  ThemeSettings() {
    _load();
  }

  final _store = LocalSettingsStore();
  ThemeMode _mode = ThemeMode.dark;
  double _textScale = 1.0;
  bool _loaded = false;

  ThemeMode get mode => _mode;
  double get textScale => _textScale;
  bool get loaded => _loaded;

  static const textScaleOptions = <(String, double)>[
    ('Маленький', 0.85),
    ('Обычный', 1.0),
    ('Крупный', 1.15),
    ('Очень крупный', 1.3),
  ];

  Future<void> _load() async {
    final stored = await _store.getString('theme_mode', 'dark');
    _mode = switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    final scaleStored = await _store.getString('text_scale', '1.0');
    _textScale = double.tryParse(scaleStored) ?? 1.0;
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
    notifyListeners();
  }

  Future<void> setTextScale(double scale) async {
    _textScale = scale;
    await _store.setString('text_scale', scale.toString());
    notifyListeners();
  }

  String get modeLabel => switch (_mode) {
        ThemeMode.light => 'Светлая',
        ThemeMode.dark => 'Тёмная',
        ThemeMode.system => 'Как в системе',
      };

  String get textScaleLabel {
    for (final o in textScaleOptions) {
      if ((o.$2 - _textScale).abs() < 0.01) return o.$1;
    }
    return 'Обычный';
  }
}
