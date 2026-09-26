import 'package:flutter/material.dart';

/// Desktop storage theme aligned with the messenger's dark OUO design system.
class OuoTheme {
  OuoTheme._();

  static const background = Color(0xFF071018);
  static const surface = Color(0xFF0D1621);
  static const card = Color(0xFF182231);
  static const cardSoft = Color(0xFF202B3A);
  static const primary = Color(0xFF425CE5);
  static const secondary = Color(0xFF7048D8);
  static const success = Color(0xFF35D07F);
  static const warning = Color(0xFFFFB020);
  static const danger = Color(0xFFFF4D5E);
  static const textPrimary = Color(0xFFF4F7FB);
  static const textSecondary = Color(0xFF9AA6B5);
  static const textMuted = Color(0xFF667085);
  static const divider = Color.fromRGBO(255, 255, 255, 0.06);

  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: primary,
      secondary: secondary,
      surface: surface,
      error: danger,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: textPrimary,
      onError: Colors.white,
    );
    const fontFallback = [
      'SF Pro Text',
      '.AppleSystemUIFont',
      'Roboto',
      'sans-serif',
    ];
    const baseText = TextStyle(
      fontFamily: 'Inter',
      fontFamilyFallback: fontFallback,
      color: textPrimary,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      fontFamily: 'Inter',
      fontFamilyFallback: fontFallback,
      textTheme: TextTheme(
        headlineMedium: baseText.copyWith(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
        titleLarge:
            baseText.copyWith(fontSize: 18, fontWeight: FontWeight.w600),
        titleMedium:
            baseText.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
        bodyLarge: baseText.copyWith(fontSize: 15, height: 1.35),
        bodyMedium:
            baseText.copyWith(fontSize: 14, color: textSecondary, height: 1.35),
        bodySmall: baseText.copyWith(fontSize: 12, color: textSecondary),
        labelLarge:
            baseText.copyWith(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dividerTheme: const DividerThemeData(color: divider, thickness: 0.5),
      dividerColor: divider,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        hintStyle: const TextStyle(color: textMuted),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(style: _buttonStyle(true)),
      outlinedButtonTheme: OutlinedButtonThemeData(style: _buttonStyle(false)),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 44),
          foregroundColor: primary,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(44, 44),
          foregroundColor: textSecondary,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(textPrimary),
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? primary : cardSoft,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: cardSoft,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: textSecondary,
        textColor: textPrimary,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: primary),
    );
  }

  static ButtonStyle _buttonStyle(bool filled) => ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
        foregroundColor: WidgetStatePropertyAll(
          filled ? Colors.white : primary,
        ),
        backgroundColor: WidgetStatePropertyAll(
          filled ? primary : Colors.transparent,
        ),
        side: filled
            ? null
            : const WidgetStatePropertyAll(
                BorderSide(color: Color(0x80425CE5)),
              ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
}
