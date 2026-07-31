/// Border radius tokens.
class AppRadius {
  AppRadius._();

  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;

  static const double button = md;
  static const double card = lg;
  static const double bubble = 20;
  static const double avatar = 999;
}

/// Legacy radius aliases.
class AppRadii {
  AppRadii._();
  static const double small = AppRadius.sm;
  static const double medium = AppRadius.md;
  static const double large = AppRadius.lg;
  static const double xLarge = AppRadius.xl;
  static const double bubble = AppRadius.bubble;
}

/// Legacy avatar sizes — see [AppAvatarSizes] in app_avatar.dart.
class AppAvatarSizes {
  AppAvatarSizes._();
  static const double small = 24;
  static const double medium = 48;
  static const double large = 96;
}
