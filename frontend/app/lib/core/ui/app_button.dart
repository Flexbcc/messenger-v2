import 'package:flutter/material.dart';

import '../extensions/context_extensions.dart';
import '../theme/app_motion.dart';
import '../theme/app_radius.dart';
import '../theme/app_shadows.dart';
import '../theme/app_spacing.dart';

enum AppButtonVariant { primary, secondary, danger }

/// Primary / secondary / danger button with press scale animation.
class AppButton extends StatefulWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.loading = false,
    this.expanded = true,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final bool loading;
  final bool expanded;
  final IconData? icon;

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: AppMotion.fast,
      lowerBound: 0.96,
      upperBound: 1,
    );
    _press.value = 1;
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final disabled = widget.onPressed == null || widget.loading;

    final child = GestureDetector(
      onTapDown: disabled ? null : (_) => _press.reverse(),
      onTapUp: disabled ? null : (_) => _press.forward(),
      onTapCancel: disabled ? null : () => _press.forward(),
      child: ScaleTransition(
        scale: _press,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: disabled ? null : widget.onPressed,
            borderRadius: BorderRadius.circular(AppRadius.button),
            child: Ink(
              height: AppSpacing.buttonHeight,
              decoration: _decoration(colors, disabled),
              child: Center(
                child: widget.loading
                    ? SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _foreground(colors, disabled),
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.icon != null) ...[
                            Icon(
                              widget.icon,
                              size: 18,
                              color: _foreground(colors, disabled),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Text(
                            widget.label,
                            style: text.subtitle.copyWith(
                              color: _foreground(colors, disabled),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );

    if (!widget.expanded) return child;
    return SizedBox(width: double.infinity, child: child);
  }

  BoxDecoration _decoration(colors, bool disabled) {
    switch (widget.variant) {
      case AppButtonVariant.primary:
        return BoxDecoration(
          gradient: disabled ? null : colors.accentGradient,
          color: disabled ? colors.cardSoft : null,
          borderRadius: BorderRadius.circular(AppRadius.button),
          boxShadow: disabled ? null : AppShadows.subtle(colors),
        );
      case AppButtonVariant.secondary:
        return BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.button),
          border: Border.all(
            color: disabled
                ? colors.divider
                : colors.primary.withValues(alpha: 0.5),
          ),
        );
      case AppButtonVariant.danger:
        return BoxDecoration(
          color: colors.danger.withValues(alpha: disabled ? 0.2 : 0.12),
          borderRadius: BorderRadius.circular(AppRadius.button),
          border: Border.all(color: colors.danger.withValues(alpha: 0.4)),
        );
    }
  }

  Color _foreground(colors, bool disabled) {
    if (disabled) return colors.textMuted;
    return switch (widget.variant) {
      AppButtonVariant.primary => colors.onAccent,
      AppButtonVariant.secondary => colors.primary,
      AppButtonVariant.danger => colors.danger,
    };
  }
}
