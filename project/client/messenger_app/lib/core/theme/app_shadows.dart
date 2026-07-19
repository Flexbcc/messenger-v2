import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Soft elevation shadows for cards and surfaces.
class AppShadows {
  AppShadows._();

  static List<BoxShadow> soft(AppColorScheme colors, {double opacity = 0.2}) => [
        BoxShadow(
          color: colors.shadow.withValues(alpha: opacity),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
      ];

  static List<BoxShadow> subtle(AppColorScheme colors) => [
        BoxShadow(
          color: colors.shadow.withValues(alpha: 0.12),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ];
}
