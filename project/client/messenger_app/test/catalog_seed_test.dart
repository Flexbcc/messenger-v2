import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/services/catalog_seed_service.dart';

void main() {
  group('CatalogSeedService.normalizeKey', () {
    test('snake_case to dot id', () {
      expect(CatalogSeedService.normalizeKey('profile_display_name'), 'profile.display_name');
      expect(CatalogSeedService.normalizeKey('profile_avatar'), 'profile.avatar');
      expect(CatalogSeedService.normalizeKey('media_autoload_wifi'), 'media.autoload_wifi');
    });

    test('dot id unchanged', () {
      expect(CatalogSeedService.normalizeKey('profile.display_name'), 'profile.display_name');
    });
  });
}
