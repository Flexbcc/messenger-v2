import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Typography scale — use via [AppTextStyles.of] for theme-aware colors.
@immutable
class AppTextStyles extends ThemeExtension<AppTextStyles> {
  const AppTextStyles({
    required this.largeTitle,
    required this.title,
    required this.sectionTitle,
    required this.subtitle,
    required this.body,
    required this.secondary,
    required this.caption,
    required this.micro,
  });

  final TextStyle largeTitle;
  final TextStyle title;
  final TextStyle sectionTitle;
  final TextStyle subtitle;
  final TextStyle body;
  final TextStyle secondary;
  final TextStyle caption;
  final TextStyle micro;

  static const _fontFamily = 'Inter';
  static const _fallback = ['SF Pro Text', '.AppleSystemUIFont', 'Roboto', 'sans-serif'];

  factory AppTextStyles.from(AppColorScheme colors) => AppTextStyles(
        largeTitle: TextStyle(
          fontFamily: _fontFamily,
          fontFamilyFallback: _fallback,
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: colors.textPrimary,
          letterSpacing: -0.3,
        ),
        title: TextStyle(
          fontFamily: _fontFamily,
          fontFamilyFallback: _fallback,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: colors.textPrimary,
        ),
        sectionTitle: TextStyle(
          fontFamily: _fontFamily,
          fontFamilyFallback: _fallback,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: colors.textPrimary,
        ),
        subtitle: TextStyle(
          fontFamily: _fontFamily,
          fontFamilyFallback: _fallback,
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: colors.textPrimary,
        ),
        body: TextStyle(
          fontFamily: _fontFamily,
          fontFamilyFallback: _fallback,
          fontSize: 15,
          fontWeight: FontWeight.w400,
          color: colors.textPrimary,
          height: 1.35,
        ),
        secondary: TextStyle(
          fontFamily: _fontFamily,
          fontFamilyFallback: _fallback,
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: colors.textSecondary,
          height: 1.35,
        ),
        caption: TextStyle(
          fontFamily: _fontFamily,
          fontFamilyFallback: _fallback,
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: colors.textSecondary,
        ),
        micro: TextStyle(
          fontFamily: _fontFamily,
          fontFamilyFallback: _fallback,
          fontSize: 11,
          fontWeight: FontWeight.w400,
          color: colors.textMuted,
        ),
      );

  static AppTextStyles of(BuildContext context) =>
      Theme.of(context).extension<AppTextStyles>() ?? AppTextStyles.from(AppColorScheme.dark);

  @override
  AppTextStyles copyWith({
    TextStyle? largeTitle,
    TextStyle? title,
    TextStyle? sectionTitle,
    TextStyle? subtitle,
    TextStyle? body,
    TextStyle? secondary,
    TextStyle? caption,
    TextStyle? micro,
  }) =>
      AppTextStyles(
        largeTitle: largeTitle ?? this.largeTitle,
        title: title ?? this.title,
        sectionTitle: sectionTitle ?? this.sectionTitle,
        subtitle: subtitle ?? this.subtitle,
        body: body ?? this.body,
        secondary: secondary ?? this.secondary,
        caption: caption ?? this.caption,
        micro: micro ?? this.micro,
      );

  @override
  AppTextStyles lerp(ThemeExtension<AppTextStyles>? other, double t) {
    if (other is! AppTextStyles) return this;
    TextStyle l(TextStyle a, TextStyle b) => TextStyle.lerp(a, b, t)!;
    return AppTextStyles(
      largeTitle: l(largeTitle, other.largeTitle),
      title: l(title, other.title),
      sectionTitle: l(sectionTitle, other.sectionTitle),
      subtitle: l(subtitle, other.subtitle),
      body: l(body, other.body),
      secondary: l(secondary, other.secondary),
      caption: l(caption, other.caption),
      micro: l(micro, other.micro),
    );
  }
}

/// Legacy static typography — dark-first literal colors (const-safe).
class AppTypography {
  AppTypography._();

  static const _fontFamily = 'Inter';
  static const _fallback = ['SF Pro Text', '.AppleSystemUIFont', 'Roboto', 'sans-serif'];

  static const largeTitle = TextStyle(
    fontFamily: _fontFamily,
    fontFamilyFallback: _fallback,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    color: Color(0xFFF4F7FB),
    letterSpacing: -0.3,
  );

  static const title = TextStyle(
    fontFamily: _fontFamily,
    fontFamilyFallback: _fallback,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: Color(0xFFF4F7FB),
  );

  static const sectionTitle = TextStyle(
    fontFamily: _fontFamily,
    fontFamilyFallback: _fallback,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: Color(0xFFF4F7FB),
  );

  static const subtitle = TextStyle(
    fontFamily: _fontFamily,
    fontFamilyFallback: _fallback,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    color: Color(0xFFF4F7FB),
  );

  static const body = TextStyle(
    fontFamily: _fontFamily,
    fontFamilyFallback: _fallback,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    color: Color(0xFFF4F7FB),
    height: 1.35,
  );

  static const secondary = TextStyle(
    fontFamily: _fontFamily,
    fontFamilyFallback: _fallback,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: Color(0xFF9AA6B5),
    height: 1.35,
  );

  static const caption = TextStyle(
    fontFamily: _fontFamily,
    fontFamilyFallback: _fallback,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: Color(0xFF9AA6B5),
  );

  static const micro = TextStyle(
    fontFamily: _fontFamily,
    fontFamilyFallback: _fallback,
    fontSize: 11,
    fontWeight: FontWeight.w400,
    color: Color(0xFF667085),
  );
}
