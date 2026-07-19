/// Per-contact trust level — drives security policies locally (no server sync yet).
enum TrustLevel {
  unknown,
  normal,
  trusted,
  highTrust;

  String get storageKey => name;

  static TrustLevel fromStorage(String? raw) {
    if (raw == null || raw.isEmpty) return TrustLevel.unknown;
    return TrustLevel.values.firstWhere(
      (v) => v.name == raw,
      orElse: () => TrustLevel.unknown,
    );
  }

  String get label => switch (this) {
        TrustLevel.unknown => 'Неизвестный',
        TrustLevel.normal => 'Обычный',
        TrustLevel.trusted => 'Доверенный',
        TrustLevel.highTrust => 'Высокое доверие',
      };

  String get shortLabel => switch (this) {
        TrustLevel.unknown => 'Неизв.',
        TrustLevel.normal => 'Обычный',
        TrustLevel.trusted => 'Доверенный',
        TrustLevel.highTrust => 'Высокое',
      };

  String get description => switch (this) {
        TrustLevel.unknown =>
          'Медиа, ссылки и превью файлов не загружаются автоматически.',
        TrustLevel.normal => 'Стандартные настройки приложения.',
        TrustLevel.trusted => 'Фотографии загружаются автоматически.',
        TrustLevel.highTrust => 'Разрешены все автоматические действия.',
      };

  bool get allowsLinkInteraction => this != TrustLevel.unknown;
  bool get allowsFilePreview => this != TrustLevel.unknown;
  bool get allowsAutoAcceptCall => this == TrustLevel.highTrust;
}
