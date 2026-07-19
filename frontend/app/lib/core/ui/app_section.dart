import 'package:flutter/material.dart';

import '../extensions/context_extensions.dart';
import '../theme/app_spacing.dart';

/// Section header with optional subtitle above a group of tiles.
class AppSection extends StatelessWidget {
  const AppSection({
    super.key,
    required this.title,
    this.subtitle,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: text.micro.copyWith(letterSpacing: 0.8, fontWeight: FontWeight.w600)),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: text.caption),
          ],
          const SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
  }
}

/// Label + value info row inside cards.
class AppInfoRow extends StatelessWidget {
  const AppInfoRow({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.onTap,
    this.showDivider = true,
  });

  final String label;
  final String value;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.cardPadding, vertical: 12),
          decoration: showDivider
              ? BoxDecoration(border: Border(bottom: BorderSide(color: colors.divider, width: 0.5)))
              : null,
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: colors.textSecondary),
                const SizedBox(width: AppSpacing.md),
              ],
              Expanded(child: Text(label, style: text.caption.copyWith(color: colors.textMuted))),
              Flexible(child: Text(value, style: text.body, textAlign: TextAlign.end, overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
      ),
    );
  }
}
