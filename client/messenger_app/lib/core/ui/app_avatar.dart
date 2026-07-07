import 'package:flutter/material.dart';

import '../extensions/context_extensions.dart';

enum AppAvatarSize { small, medium, large }

class AppAvatarSizes {
  AppAvatarSizes._();
  static const double small = 24;
  static const double medium = 48;
  static const double large = 96;
}

/// Avatar with initials, group icon, or image + optional online indicator.
class AppAvatar extends StatelessWidget {
  const AppAvatar({
    super.key,
    this.imageProvider,
    this.label,
    this.isGroup = false,
    this.size = AppAvatarSize.medium,
    this.showOnline = false,
  });

  final ImageProvider? imageProvider;
  final String? label;
  final bool isGroup;
  final AppAvatarSize size;
  final bool showOnline;

  double get _diameter => switch (size) {
        AppAvatarSize.small => AppAvatarSizes.small,
        AppAvatarSize.medium => AppAvatarSizes.medium,
        AppAvatarSize.large => AppAvatarSizes.large,
      };

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    Widget avatar;
    if (imageProvider != null) {
      avatar = CircleAvatar(radius: _diameter / 2, backgroundImage: imageProvider);
    } else {
      final initials = (label != null && label!.isNotEmpty) ? label!.characters.first.toUpperCase() : '';
      avatar = CircleAvatar(
        radius: _diameter / 2,
        backgroundColor: colors.cardSoft,
        child: isGroup
            ? Icon(Icons.groups_outlined, color: colors.textSecondary, size: _diameter * 0.45)
            : Text(
                initials,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: _diameter * 0.38,
                  fontWeight: FontWeight.w600,
                ),
              ),
      );
    }

    if (!showOnline) return avatar;

    return SizedBox(
      width: _diameter,
      height: _diameter,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: _diameter * 0.28,
              height: _diameter * 0.28,
              decoration: BoxDecoration(
                color: colors.success,
                shape: BoxShape.circle,
                border: Border.all(color: colors.background, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
