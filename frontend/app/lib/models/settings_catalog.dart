// Data model for the settings catalog loaded from
// `assets/settings/ouo-settings-spec.json` — the single source of truth shared
// with the web/PWA client, admin panel and server validation
// (see ../../../ouo-settings-web-spec). The client renders settings from this
// catalog instead of hardcoding them screen-by-screen.

class SettingsCatalog {
  const SettingsCatalog({required this.product, required this.sections});

  final String product;
  final List<CatalogSection> sections;

  factory SettingsCatalog.fromJson(Map<String, dynamic> json) {
    final meta = (json['meta'] as Map<String, dynamic>?) ?? const {};
    final rawSections = (json['sections'] as List<dynamic>? ?? const []);
    return SettingsCatalog(
      product: meta['product'] as String? ?? 'OUO Messenger',
      sections: rawSections
          .whereType<Map<String, dynamic>>()
          .map(CatalogSection.fromJson)
          .toList(growable: false),
    );
  }

  CatalogSection? sectionById(String id) {
    for (final s in sections) {
      if (s.id == id) return s;
    }
    return null;
  }

  SettingDef? settingById(String id) {
    for (final s in sections) {
      for (final def in s.settings) {
        if (def.id == id) return def;
      }
    }
    return null;
  }
}

class CatalogSection {
  const CatalogSection({
    required this.id,
    required this.title,
    required this.settings,
  });

  final String id;
  final String title;
  final List<SettingDef> settings;

  factory CatalogSection.fromJson(Map<String, dynamic> json) {
    final rawSettings = (json['settings'] as List<dynamic>? ?? const []);
    return CatalogSection(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? json['id'] as String? ?? '',
      settings: rawSettings
          .whereType<Map<String, dynamic>>()
          .map(SettingDef.fromJson)
          .toList(growable: false),
    );
  }
}

class SettingDef {
  const SettingDef({
    required this.id,
    required this.title,
    required this.type,
    required this.description,
    required this.options,
    required this.defaultValue,
    required this.scope,
    required this.storage,
    required this.danger,
    required this.requiresConfirmation,
    required this.visibleIf,
  });

  final String id;
  final String title;
  final String type; // boolean|single_select|multi_select|text|number|secret|read_only|action|list
  final String description;
  final List<String> options;
  final Object? defaultValue;
  final String scope; // profile|device
  final String storage; // profile_settings|local_encrypted|none
  final bool danger;
  final bool requiresConfirmation;
  final VisibleIf? visibleIf;

  /// Whether this setting holds a persistable value (vs actions / read-only).
  bool get isPersistable =>
      storage != 'none' && type != 'action' && type != 'read_only';

  /// Secrets are never rendered as plain editable values in this catalog view.
  bool get isSecret => type == 'secret' || storage == 'local_encrypted';

  factory SettingDef.fromJson(Map<String, dynamic> json) {
    final ui = (json['ui'] as Map<String, dynamic>?) ?? const {};
    final rawOptions = (json['options'] as List<dynamic>? ?? const []);
    return SettingDef(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? json['id'] as String? ?? '',
      type: json['type'] as String? ?? 'read_only',
      description: json['description'] as String? ?? '',
      options: rawOptions.map((e) => e.toString()).toList(growable: false),
      defaultValue: json['default'],
      scope: json['scope'] as String? ?? 'profile',
      storage: json['storage'] as String? ?? 'profile_settings',
      danger: ui['danger'] as bool? ?? false,
      requiresConfirmation: ui['requires_confirmation'] as bool? ?? false,
      visibleIf: VisibleIf.fromJson(json['visible_if']),
    );
  }
}

/// Dependency rule: a setting is shown only when the referenced setting matches.
class VisibleIf {
  const VisibleIf({required this.setting, this.equals, this.inValues});

  final String setting;
  final Object? equals;
  final List<String>? inValues;

  static VisibleIf? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final setting = raw['setting'] as String?;
    if (setting == null) return null;
    final inList = raw['in'] as List<dynamic>?;
    return VisibleIf(
      setting: setting,
      equals: raw.containsKey('equals') ? raw['equals'] : null,
      inValues: inList?.map((e) => e.toString()).toList(growable: false),
    );
  }

  bool isSatisfiedBy(Object? currentValue) {
    if (inValues != null) {
      return inValues!.contains(currentValue?.toString());
    }
    if (equals != null) {
      return currentValue == equals || currentValue?.toString() == equals.toString();
    }
    // Bare dependency with no operator: treat truthy as visible.
    return currentValue == true;
  }
}
