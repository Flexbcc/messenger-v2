import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/models/settings_blocks.dart';
import 'package:messenger_app/models/settings_catalog.dart';
import 'package:messenger_app/models/settings_impl_status.dart';

void main() {
  late SettingsCatalog catalog;

  setUpAll(() {
    final raw = File(
      'assets/settings/ouo-settings-spec.json',
    ).readAsStringSync();
    catalog = SettingsCatalog.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    ).withoutSettings(SettingsImplStatus.retiredIds);
  });

  test('every catalog section belongs to exactly one thematic block', () {
    final owners = <String, List<String>>{};
    for (final block in kSettingsBlocks) {
      for (final sectionId in block.sectionIds) {
        owners.putIfAbsent(sectionId, () => []).add(block.id);
      }
    }

    for (final section in catalog.sections) {
      expect(
        owners[section.id],
        hasLength(1),
        reason: '${section.id} must have one thematic owner',
      );
    }
  });

  test('dedicated sections are not repeated as catalog entries on hub', () {
    final catalogEntriesOnHub = kSettingsBlocks
        .expand((block) => block.sectionIds)
        .where((id) => !kDedicatedSettingsSections.containsKey(id))
        .toList();

    expect(catalogEntriesOnHub, hasLength(catalogEntriesOnHub.toSet().length));
    expect(
      catalogEntriesOnHub.toSet().intersection(
        kDedicatedSettingsSections.keys.toSet(),
      ),
      isEmpty,
    );
  });

  test('embedded catalog sections cannot navigate back to their parent', () {
    for (final entry in kEmbeddedCatalogSettingIds.entries) {
      final section = catalog.sectionById(entry.key);
      expect(section, isNotNull, reason: 'Unknown section ${entry.key}');
      final embedded = section!.settings
          .where((setting) => entry.value.contains(setting.id))
          .toList();
      expect(embedded, isNotEmpty);
      expect(
        embedded.where((setting) => setting.type == 'action'),
        isEmpty,
        reason: '${entry.key} embeds an action that may create a route cycle',
      );
    }
  });

  test('service sections are hidden from the ordinary settings surface', () {
    final ordinarySections = kSettingsBlocks
        .expand((block) => block.sectionIds)
        .where((id) => !kDedicatedSettingsSections.containsKey(id))
        .where((id) => !kServiceSettingsSectionIds.contains(id))
        .toSet();

    expect(ordinarySections.intersection(kServiceSettingsSectionIds), isEmpty);
    for (final id in kServiceSettingsSectionIds) {
      expect(
        catalog.sectionById(id),
        isNotNull,
        reason: 'Unknown service section $id',
      );
    }
    expect(kServiceSettingsSectionIds, contains('developer'));
    expect(kServiceSettingsSectionIds, contains('storage_ownership'));
  });

  test('settings block identifiers and section identifiers are unique', () {
    final blockIds = [
      ...kSettingsBlocks.map((block) => block.id),
      ...kHubSettingsBlocks.map((block) => block.id),
    ];
    expect(blockIds, hasLength(blockIds.toSet().length));

    final sectionIds = catalog.sections.map((section) => section.id).toList();
    expect(sectionIds, hasLength(sectionIds.toSet().length));
  });

  test('repeated setting titles stay limited to intentional contexts', () {
    String normalize(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'[^a-zа-я0-9]+'), ' ').trim();

    final byTitle = <String, List<String>>{};
    for (final section in catalog.sections) {
      for (final setting in section.settings) {
        byTitle
            .putIfAbsent(normalize(setting.title), () => <String>[])
            .add(setting.id);
      }
    }

    final duplicates = {
      for (final entry in byTitle.entries)
        if (entry.value.length > 1) entry.key: entry.value.toSet(),
    };
    const intentional = {
      'выбранные пользователи': {
        'privacy.phone_visibility_list',
        'privacy.email_visibility_list',
      },
      'исключения': {'privacy.last_seen_list', 'notifications.dnd_exceptions'},
      'фейковый pin': {'security.fake_pin_enabled', 'security.fake_pin'},
    };

    expect(duplicates, intentional);
  });
}
