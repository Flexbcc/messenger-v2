import 'package:flutter/material.dart';

import '../extensions/context_extensions.dart';
import '../theme/app_motion.dart';
import '../theme/app_spacing.dart';
import 'app_button.dart';

/// Centered empty state with fade-in animation.
class AppEmptyState extends StatefulWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  State<AppEmptyState> createState() => _AppEmptyStateState();
}

class _AppEmptyStateState extends State<AppEmptyState> with SingleTickerProviderStateMixin {
  late final AnimationController _fade;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(vsync: this, duration: AppMotion.slow)..forward();
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return FadeTransition(
      opacity: CurvedAnimation(parent: _fade, curve: AppMotion.enter),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(widget.icon, size: 64, color: colors.primary.withValues(alpha: 0.55)),
            const SizedBox(height: AppSpacing.lg),
            Text(widget.title, textAlign: TextAlign.center, style: text.largeTitle),
            if (widget.subtitle != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(widget.subtitle!, textAlign: TextAlign.center, style: text.secondary),
            ],
            if (widget.actionLabel != null && widget.onAction != null) ...[
              const SizedBox(height: AppSpacing.xl),
              AppButton(label: widget.actionLabel!, onPressed: widget.onAction),
            ],
          ],
        ),
      ),
    );
  }
}
