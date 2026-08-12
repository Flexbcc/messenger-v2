import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/models/settings_catalog.dart';
import 'package:messenger_app/models/settings_impl_status.dart';

/// Verifies the shared settings catalog asset parses into the client model.
/// This is the wiring that connects the Flutter client to the single source of
/// truth (ouo-settings-spec.json) — previously absent (see AUDIT.md).
void main() {
  test('parses ouo-settings-spec.json asset into catalog', () {
    final raw = File(
      'assets/settings/ouo-settings-spec.json',
    ).readAsStringSync();
    final catalog = SettingsCatalog.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );

    // 18 sections per the audited spec.
    expect(catalog.sections.length, 18);

    final totalSettings = catalog.sections.fold<int>(
      0,
      (sum, s) => sum + s.settings.length,
    );
    expect(totalSettings, greaterThan(150)); // 184 in the audited spec

    // Every setting has a non-empty id and a known type.
    const knownTypes = {
      'boolean',
      'single_select',
      'multi_select',
      'text',
      'number',
      'secret',
      'read_only',
      'action',
      'list',
    };
    for (final section in catalog.sections) {
      for (final def in section.settings) {
        expect(def.id, isNotEmpty, reason: 'setting id empty in ${section.id}');
        expect(
          knownTypes.contains(def.type),
          isTrue,
          reason: 'bad type ${def.type} for ${def.id}',
        );
      }
    }

    // Sanity: a known boolean and a known select resolve correctly.
    final security = catalog.sectionById('security');
    expect(security, isNotNull);
    final pinEnabled = security!.settings.firstWhere(
      (d) => d.id == 'security.pin_enabled',
    );
    expect(pinEnabled.type, 'boolean');
    expect(pinEnabled.isPersistable, isTrue);

    // Secrets are flagged and excluded from generic editing.
    final pin = security.settings.firstWhere((d) => d.id == 'security.pin');
    expect(pin.isSecret, isTrue);
  });

  test(
    'obsolete distributed-node settings are excluded from the PWA catalog',
    () {
      final raw = File(
        'assets/settings/ouo-settings-spec.json',
      ).readAsStringSync();
      final catalog = SettingsCatalog.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      ).withoutSettings(SettingsImplStatus.retiredIds);

      expect(SettingsImplStatus.isVerified('backup.create_now'), isTrue);
      expect(catalog.settingById('sync.enabled'), isNotNull);
      expect(catalog.settingById('sync.history_depth'), isNotNull);
      expect(catalog.settingById('storage.media_ttl'), isNotNull);
      expect(catalog.settingById('storage.access_devices')?.type, 'action');
      expect(catalog.settingById('storage.s3_secret_key'), isNull);
      expect(catalog.settingById('node.proxy_enabled'), isNull);
      final ids = catalog.sections.expand(
        (section) => section.settings.map((setting) => setting.id),
      );
      expect(SettingsImplStatus.stubCount(ids), 0);

      expect(SettingsImplStatus.isLive('appearance.theme'), isTrue);
      expect(SettingsImplStatus.isLive('messages.send_key'), isTrue);
      expect(SettingsImplStatus.isLive('node.custom_address'), isTrue);
      expect(SettingsImplStatus.isVerified('appearance.theme'), isTrue);
      expect(
        SettingsImplStatus.isWiredUnverified('node.custom_address'),
        isTrue,
      );
    },
  );

  test(
    'all visibility dependencies reference existing settings and are acyclic',
    () {
      final raw = File(
        'assets/settings/ouo-settings-spec.json',
      ).readAsStringSync();
      final catalog = SettingsCatalog.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      ).withoutSettings(SettingsImplStatus.retiredIds);
      final settings = {
        for (final def in catalog.sections.expand((s) => s.settings))
          def.id: def,
      };

      for (final def in settings.values) {
        final dependency = def.visibleIf?.setting;
        if (dependency == null) continue;
        expect(
          settings.containsKey(dependency),
          isTrue,
          reason: '${def.id} depends on missing $dependency',
        );

        final visited = <String>{def.id};
        var current = dependency;
        while (settings[current]?.visibleIf != null) {
          expect(
            visited.add(current),
            isTrue,
            reason: 'visibility dependency cycle at ${def.id}',
          );
          current = settings[current]!.visibleIf!.setting;
        }
      }
    },
  );

  test(
    'private settings follow primary PIN, additional PIN, secret features',
    () {
      final raw = File(
        'assets/settings/ouo-settings-spec.json',
      ).readAsStringSync();
      final catalog = SettingsCatalog.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      ).withoutSettings(SettingsImplStatus.retiredIds);

      expect(
        catalog.settingById('security.fake_pin_enabled')?.visibleIf?.setting,
        'security.pin_enabled',
      );
      expect(
        catalog.settingById('security.fake_pin')?.visibleIf?.setting,
        'security.fake_pin_enabled',
      );
      expect(
        catalog.settingById('hidden.enabled')?.visibleIf?.setting,
        'security.fake_pin_enabled',
      );
      expect(
        catalog
            .settingById('devices.hidden_access_default')
            ?.visibleIf
            ?.setting,
        'security.fake_pin_enabled',
      );
    },
  );
}
