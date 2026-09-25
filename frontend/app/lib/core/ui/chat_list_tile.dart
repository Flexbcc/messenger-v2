import 'package:flutter/material.dart';

import '../extensions/context_extensions.dart';
import '../theme/app_motion.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import 'app_avatar.dart';
import 'app_badge.dart';

/// Chat list row — avatar, name/time, preview, unread badge.
class ChatListTile extends StatelessWidget {
  const ChatListTile({
    super.key,
    required this.title,
    required this.subtitle,
    this.timeLabel,
    this.unreadCount = 0,
    this.isOnline = false,
    this.isGroup = false,
    this.isPinned = false,
    this.isMuted = false,
    this.selected = false,
    this.unreachable = false,
    this.onTap,
    this.avatarLabel,
  });

  final String title;
  final String subtitle;
  final String? timeLabel;
  final int unreadCount;
  final bool isOnline;
  final bool isGroup;
  final bool isPinned;
  final bool isMuted;
  final bool selected;
  final bool unreachable;
  final VoidCallback? onTap;
  final String? avatarLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final compact = Theme.of(context).visualDensity.vertical < 0;
    final outerV = compact ? 2.0 : 4.0;
    final innerV = compact ? 6.0 : 10.0;
    final previewGap = compact ? 2.0 : 4.0;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AppSpacing.screenPadding,
        vertical: outerV,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: AnimatedContainer(
            duration: AppMotion.normal,
            curve: AppMotion.standard,
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: innerV),
            decoration: BoxDecoration(
              color: selected ? colors.cardSoft : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: selected
                  ? Border.all(color: colors.primary.withValues(alpha: 0.25))
                  : null,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppAvatar(
                  label: avatarLabel ?? (isGroup ? null : title),
                  isGroup: isGroup,
                  showOnline: isOnline && !isGroup,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (isPinned) ...[
                            Icon(
                              Icons.push_pin,
                              size: 12,
                              color: colors.textMuted,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.subtitle.copyWith(
                                fontWeight: unreadCount > 0
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                          if (isMuted) ...[
                            const SizedBox(width: 4),
                            Icon(
                              Icons.notifications_off_outlined,
                              size: 14,
                              color: colors.textMuted,
                            ),
                          ],
                          if (timeLabel != null) ...[
                            const SizedBox(width: 6),
                            Text(timeLabel!, style: text.micro),
                          ],
                        ],
                      ),
                      SizedBox(height: previewGap),
                      Text(
                        subtitle,
                        maxLines: compact ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.caption.copyWith(
                          color: unreachable
                              ? colors.danger.withValues(alpha: 0.85)
                              : colors.textSecondary,
                          fontWeight: unreadCount > 0
                              ? FontWeight.w500
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                UnreadBadge(count: unreadCount),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
