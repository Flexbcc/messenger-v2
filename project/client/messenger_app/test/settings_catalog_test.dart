import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/models/settings_catalog.dart';

/// Verifies the shared settings catalog asset parses into the client model.
/// This is the wiring that connects the Flutter client to the single source of
/// truth (ouo-settings-spec.json) — previously absent (see AUDIT.md).
void main() {
  test('parses ouo-settings-spec.json asset into catalog', () {
    final raw = File('assets/settings/ouo-settings-spec.json').readAsStringSync();
    final catalog = SettingsCatalog.fromJson(jsonDecode(raw) as Map<String, dynamic>);

    // 18 sections per the audited spec.
    expect(catalog.sections.length, 18);

    final totalSettings =
        catalog.sections.fold<int>(0, (sum, s) => sum + s.settings.length);
    expect(totalSettings, greaterThan(150)); // 184 in the audited spec

    // Every setting has a non-empty id and a known type.
    const knownTypes = {
      'boolean', 'single_select', 'multi_select', 'text',
      'number', 'secret', 'read_only', 'action', 'list',
    };
    for (final section in catalog.sections) {
      for (final def in section.settings) {
        expect(def.id, isNotEmpty, reason: 'setting id empty in ${section.id}');
        expect(knownTypes.contains(def.type), isTrue, reason: 'bad type ${def.type} for ${def.id}');
      }
    }

    // Sanity: a known boolean and a known select resolve correctly.
    final security = catalog.sectionById('security');
    expect(security, isNotNull);
    final pinEnabled =
        security!.settings.firstWhere((d) => d.id == 'security.pin_enabled');
    expect(pinEnabled.type, 'boolean');
    expect(pinEnabled.isPersistable, isTrue);

    // Secrets are flagged and excluded from generic editing.
    final pin = security.settings.firstWhere((d) => d.id == 'security.pin');
    expect(pin.isSecret, isTrue);
  });
}
