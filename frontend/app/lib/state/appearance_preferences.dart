import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/settings_catalog_bridge.dart';

/// Appearance prefs from catalog (compact, text size, animations).
class AppearancePreferences {
  AppearancePreferences(this._reader);

  final CatalogSettingsReader _reader;

  Future<String> theme() => _reader.getString('appearance.theme', 'system');

  Future<bool> compact() => _reader.getBool('appearance.compact', false);

  Future<String> textSize() =>
      _reader.getString('appearance.text_size', 'normal');

  Future<bool> animations() => _reader.getBool('appearance.animations', true);

  Future<bool> reduceMotion() =>
      _reader.getBool('appearance.reduce_motion', false);

  Future<String> chatBubbles() =>
      _reader.getString('appearance.chat_bubbles', 'bubbles');
}

final appearancePreferencesProvider = Provider<AppearancePreferences>(
  (ref) => AppearancePreferences(CatalogSettingsReader()),
);

final messagePreferencesProvider = Provider<CatalogSettingsReader>(
  (ref) => CatalogSettingsReader(),
);
