import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

extension AppThemeContext on BuildContext {
  AppColorScheme get colors => Theme.of(this).extension<AppColorScheme>() ?? AppColorScheme.dark;

  AppTextStyles get textStyles => AppTextStyles.of(this);

  bool get isDark => Theme.of(this).brightness == Brightness.dark;
}
