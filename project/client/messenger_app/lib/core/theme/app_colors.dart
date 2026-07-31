import 'package:flutter/material.dart';

/// Semantic color scheme resolved from theme brightness.
@immutable
class AppColorScheme extends ThemeExtension<AppColorScheme> {
  const AppColorScheme({
    required this.background,
    required this.surface,
    required this.surfaceElevated,
    required this.card,
    required this.cardSoft,
    required this.primary,
    required this.secondary,
    required this.success,
    required this.warning,
    required this.danger,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.divider,
    required this.shadow,
    required this.chatIncoming,
    required this.chatOutgoingStart,
    required this.chatOutgoingEnd,
  });

  final Color background;
  final Color surface;
  final Color surfaceElevated;
  final Color card;
  final Color cardSoft;
  final Color primary;
  final Color secondary;
  final Color success;
  final Color warning;
  final Color danger;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color divider;
  final Color shadow;
  final Color chatIncoming;
  final Color chatOutgoingStart;
  final Color chatOutgoingEnd;

  static const dark = AppColorScheme(
    background: Color(0xFF071018),
    surface: Color(0xFF0D1621),
    surfaceElevated: Color(0xFF121D2B),
    card: Color(0xFF182231),
    cardSoft: Color(0xFF202B3A),
    primary: Color(0xFF4F6BFF),
    secondary: Color(0xFF8B5CF6),
    success: Color(0xFF35D07F),
    warning: Color(0xFFFFB020),
    danger: Color(0xFFFF4D5E),
    textPrimary: Color(0xFFF4F7FB),
    textSecondary: Color(0xFF9AA6B5),
    textMuted: Color(0xFF667085),
    divider: Color.fromRGBO(255, 255, 255, 0.06),
    shadow: Colors.black,
    chatIncoming: Color(0xFF182231),
    chatOutgoingStart: Color(0xFF4F6BFF),
    chatOutgoingEnd: Color(0xFF8B5CF6),
  );

  static const light = AppColorScheme(
    background: Color(0xFFF5F7FB),
    surface: Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFFFFFFF),
    card: Color(0xFFFFFFFF),
    cardSoft: Color(0xFFF1F3F7),
    primary: Color(0xFF2563EB),
    secondary: Color(0xFF7C3AED),
    success: Color(0xFF16A34A),
    warning: Color(0xFFD97706),
    danger: Color(0xFFEF4444),
    textPrimary: Color(0xFF0F172A),
    textSecondary: Color(0xFF64748B),
    textMuted: Color(0xFF94A3B8),
    divider: Color.fromRGBO(15, 23, 42, 0.08),
    shadow: Color(0xFF0F172A),
    chatIncoming: Color(0xFFF1F3F7),
    chatOutgoingStart: Color(0xFF2563EB),
    chatOutgoingEnd: Color(0xFF7C3AED),
  );

  LinearGradient get outgoingGradient => LinearGradient(
        colors: [chatOutgoingStart, chatOutgoingEnd],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  LinearGradient get accentGradient => LinearGradient(
        colors: [primary, secondary],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      );

  @override
  AppColorScheme copyWith({
    Color? background,
    Color? surface,
    Color? surfaceElevated,
    Color? card,
    Color? cardSoft,
    Color? primary,
    Color? secondary,
    Color? success,
    Color? warning,
    Color? danger,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? divider,
    Color? shadow,
    Color? chatIncoming,
    Color? chatOutgoingStart,
    Color? chatOutgoingEnd,
  }) =>
      AppColorScheme(
        background: background ?? this.background,
        surface: surface ?? this.surface,
        surfaceElevated: surfaceElevated ?? this.surfaceElevated,
        card: card ?? this.card,
        cardSoft: cardSoft ?? this.cardSoft,
        primary: primary ?? this.primary,
        secondary: secondary ?? this.secondary,
        success: success ?? this.success,
        warning: warning ?? this.warning,
        danger: danger ?? this.danger,
        textPrimary: textPrimary ?? this.textPrimary,
        textSecondary: textSecondary ?? this.textSecondary,
        textMuted: textMuted ?? this.textMuted,
        divider: divider ?? this.divider,
        shadow: shadow ?? this.shadow,
        chatIncoming: chatIncoming ?? this.chatIncoming,
        chatOutgoingStart: chatOutgoingStart ?? this.chatOutgoingStart,
        chatOutgoingEnd: chatOutgoingEnd ?? this.chatOutgoingEnd,
      );

  @override
  AppColorScheme lerp(ThemeExtension<AppColorScheme>? other, double t) {
    if (other is! AppColorScheme) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColorScheme(
      background: l(background, other.background),
      surface: l(surface, other.surface),
      surfaceElevated: l(surfaceElevated, other.surfaceElevated),
      card: l(card, other.card),
      cardSoft: l(cardSoft, other.cardSoft),
      primary: l(primary, other.primary),
      secondary: l(secondary, other.secondary),
      success: l(success, other.success),
      warning: l(warning, other.warning),
      danger: l(danger, other.danger),
      textPrimary: l(textPrimary, other.textPrimary),
      textSecondary: l(textSecondary, other.textSecondary),
      textMuted: l(textMuted, other.textMuted),
      divider: l(divider, other.divider),
      shadow: l(shadow, other.shadow),
      chatIncoming: l(chatIncoming, other.chatIncoming),
      chatOutgoingStart: l(chatOutgoingStart, other.chatOutgoingStart),
      chatOutgoingEnd: l(chatOutgoingEnd, other.chatOutgoingEnd),
    );
  }
}

/// Legacy static accessors — prefer [AppColorScheme] via `context.colors`.
class AppColors {
  AppColors._();

  static const background = Color(0xFF071018);
  static const surface = Color(0xFF0D1621);
  static const card = Color(0xFF182231);
  static const cardSoft = Color(0xFF202B3A);
  static const primary = Color(0xFF4F6BFF);
  static const secondary = Color(0xFF8B5CF6);
  static const successGreen = Color(0xFF35D07F);
  static const warningYellow = Color(0xFFFFB020);
  static const dangerRed = Color(0xFFFF4D5E);
  static const textMain = Color(0xFFF4F7FB);
  static const textSecondary = Color(0xFF9AA6B5);
  static const textMuted = Color(0xFF667085);
  static const divider = Color.fromRGBO(255, 255, 255, 0.06);

  static const backgroundLight = background;
  static const backgroundDark = background;
  static const backgroundElevated = Color(0xFF121D2B);
  static const surfaceLight = card;
  static const surfaceDark = surface;
  static const textPrimary = textMain;
  static const textInverse = textMain;
  static const borderLight = divider;
  static const borderDark = divider;
  static const accentBlue = primary;
  static const accentViolet = secondary;
  static const chatIncoming = Color(0xFF182231);
  static const chatOutgoingText = textMain;
  static const chatIncomingText = textMain;
  static const chatOutgoing = primary;
  static const outgoingGradientStart = Color(0xFF4F6BFF);
  static const outgoingGradientEnd = Color(0xFF8B5CF6);
  static const callBackdropTop = surface;
  static const callBackdropBottom = background;
  static const cardSecondary = cardSoft;
}
