import 'package:flutter/material.dart';

import '../extensions/context_extensions.dart';
import '../theme/app_radius.dart';
import '../theme/app_shadows.dart';
import '../theme/app_spacing.dart';

/// Rounded surface card — primary container for grouped content.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.cardPadding),
    this.margin,
    this.onTap,
    this.selected = false,
    this.color,
    this.radius = AppRadius.card,
    this.shadow = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final bool selected;
  final Color? color;
  final double radius;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final decoration = BoxDecoration(
      color: selected ? colors.cardSoft : (color ?? colors.card),
      borderRadius: BorderRadius.circular(radius),
      border: selected ? Border.all(color: colors.primary.withValues(alpha: 0.35)) : null,
      boxShadow: shadow ? AppShadows.subtle(colors) : null,
    );

    final content = Container(margin: margin, padding: padding, decoration: decoration, child: child);

    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(radius), child: content),
    );
  }
}

/// Grouped settings rows inside one card.
class AppSettingsGroup extends StatelessWidget {
  const AppSettingsGroup({
    super.key,
    this.title,
    required this.children,
    this.margin = const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
  });

  final String? title;
  final List<Widget> children;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: AppSpacing.sm),
              child: Text(
                title!.toUpperCase(),
                style: context.textStyles.micro.copyWith(letterSpacing: 0.8, fontWeight: FontWeight.w600),
              ),
            ),
          AppCard(padding: EdgeInsets.zero, child: Column(children: children)),
        ],
      ),
    );
  }
}
