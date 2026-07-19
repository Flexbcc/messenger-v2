import 'package:flutter/material.dart';

import '../extensions/context_extensions.dart';
import '../theme/app_spacing.dart';

/// Standard list/settings row.
class AppTile extends StatelessWidget {
  const AppTile({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailingText,
    this.trailing,
    this.onTap,
    this.showDivider = false,
    this.danger = false,
    this.dense = false,
    this.enabled = true,
  });

  final Widget? leading;
  final String title;
  final String? subtitle;
  final String? trailingText;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showDivider;
  final bool danger;
  final bool dense;
  final bool enabled;

  static Widget chevron(BuildContext context) =>
      Icon(Icons.chevron_right, color: context.colors.textMuted, size: 20);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            constraints: BoxConstraints(minHeight: dense ? 48 : AppSpacing.rowHeight),
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.cardPadding, vertical: dense ? 10 : 12),
            decoration: showDivider
                ? BoxDecoration(border: Border(bottom: BorderSide(color: colors.divider, width: 0.5)))
                : null,
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: AppSpacing.md)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.subtitle.copyWith(color: danger ? colors.danger : colors.textPrimary),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.caption),
                      ],
                    ],
                  ),
                ),
                if (trailingText != null)
                  Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.sm),
                    child: Text(trailingText!, style: text.caption.copyWith(color: colors.textMuted)),
                  ),
                if (trailing != null) trailing!,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Legacy name used across existing screens.
typedef AppListTile = AppTile;
