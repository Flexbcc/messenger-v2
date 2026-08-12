import 'package:flutter/material.dart';

import '../extensions/context_extensions.dart';
import '../theme/app_radius.dart';

/// Themed icon button with optional filled background.
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.filled = false,
    this.color,
    this.size = 40,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool filled;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final fg = color ?? (filled ? colors.textPrimary : colors.textSecondary);

    final button = filled
        ? IconButton(
            onPressed: onPressed,
            icon: Icon(icon, size: 20),
            style: IconButton.styleFrom(
              backgroundColor: colors.primary,
              foregroundColor: colors.textPrimary,
              disabledBackgroundColor: colors.cardSoft,
              disabledForegroundColor: colors.textMuted,
              minimumSize: Size(size, size),
            ),
          )
        : IconButton(
            onPressed: onPressed,
            icon: Icon(icon, size: 22, color: fg),
            style: IconButton.styleFrom(minimumSize: Size(size, size)),
          );

    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// Circular action button for profile quick actions.
class AppQuickAction extends StatelessWidget {
  const AppQuickAction({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: colors.cardSoft,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(icon, color: colors.primary, size: 22),
            ),
            const SizedBox(height: 6),
            Text(label, style: text.micro),
          ],
        ),
      ),
    );
  }
}
