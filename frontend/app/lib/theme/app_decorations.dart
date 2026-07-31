export '../core/theme/app_colors.dart';
export '../core/theme/app_radius.dart';
export '../core/theme/app_shadows.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_radius.dart';
import '../core/theme/app_shadows.dart';
import 'package:flutter/material.dart';

/// Legacy decorations — prefer [AppColorScheme.accentGradient] via context.
class AppDecorations {
  AppDecorations._();

  static LinearGradient get outgoingBubbleGradient => AppColorScheme.dark.outgoingGradient;
  static LinearGradient get accentGradient => AppColorScheme.dark.accentGradient;

  static List<BoxShadow> softShadow({double opacity = 0.22}) =>
      AppShadows.soft(AppColorScheme.dark, opacity: opacity);

  static BoxDecoration card({
    Color color = AppColors.card,
    double radius = AppRadius.lg,
    bool shadow = true,
  }) =>
      BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: shadow ? softShadow() : null,
      );
}
