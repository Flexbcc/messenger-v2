import 'package:flutter/material.dart';

import '../extensions/context_extensions.dart';
import '../theme/app_radius.dart';

/// Unread count or status badge.
class AppBadge extends StatelessWidget {
  const AppBadge({
    super.key,
    required this.label,
    this.color,
    this.gradient = true,
  });

  final String label;
  final Color? color;
  final bool gradient;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    return Container(
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        gradient: gradient && color == null ? colors.accentGradient : null,
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: context.textStyles.micro.copyWith(
          color: colors.onAccent,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
    );
  }
}

class AppSecurityBadge extends StatelessWidget {
  const AppSecurityBadge({
    super.key,
    required this.icon,
    required this.label,
    this.color,
  });

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final c = color ?? colors.primary;
    final text = context.textStyles;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: c.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: c),
          const SizedBox(width: 6),
          Text(
            label,
            style: text.micro.copyWith(color: c, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

typedef SecurityFeatureBadge = AppSecurityBadge;

class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final label = count > 99 ? '99+' : '$count';
    return AppBadge(label: label);
  }
}

enum AppStatus { online, offline, error, warning }

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.status, this.diameter = 10});

  final AppStatus status;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = switch (status) {
      AppStatus.online => colors.success,
      AppStatus.offline => colors.textMuted,
      AppStatus.error => colors.danger,
      AppStatus.warning => colors.warning,
    };

    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
