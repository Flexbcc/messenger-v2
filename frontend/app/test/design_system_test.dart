import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/core/theme/app_colors.dart';

double _contrast(Color foreground, Color background) {
  final lighter = foreground.computeLuminance() > background.computeLuminance()
      ? foreground
      : background;
  final darker = identical(lighter, foreground) ? background : foreground;
  return (lighter.computeLuminance() + 0.05) /
      (darker.computeLuminance() + 0.05);
}

void main() {
  for (final entry in <(String, AppColorScheme)>[
    ('dark', AppColorScheme.dark),
    ('light', AppColorScheme.light),
  ]) {
    test('${entry.$1} palette keeps readable semantic foregrounds', () {
      final colors = entry.$2;

      expect(
        _contrast(colors.textPrimary, colors.background),
        greaterThanOrEqualTo(7),
      );
      expect(
        _contrast(colors.textSecondary, colors.background),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(colors.onAccent, colors.primary),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(colors.onAccent, colors.secondary),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(colors.danger, colors.background),
        greaterThanOrEqualTo(4.5),
      );
    });
  }
}
