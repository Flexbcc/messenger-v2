import 'package:flutter/material.dart';

import '../extensions/context_extensions.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';

enum AppNoticeTone { info, success, warning, danger }

/// Consistent inline feedback for forms and settings flows.
class AppNotice extends StatelessWidget {
  const AppNotice({
    super.key,
    required this.message,
    this.tone = AppNoticeTone.info,
  });

  final String message;
  final AppNoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final (color, icon) = switch (tone) {
      AppNoticeTone.info => (colors.primary, Icons.info_outline),
      AppNoticeTone.success => (colors.success, Icons.check_circle_outline),
      AppNoticeTone.warning => (colors.warning, Icons.warning_amber_outlined),
      AppNoticeTone.danger => (colors.danger, Icons.error_outline),
    };

    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          border: Border.all(color: color.withValues(alpha: 0.28)),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                style: text.caption.copyWith(color: colors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
