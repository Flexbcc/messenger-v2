import 'dart:async';

import 'package:flutter/material.dart';

import '../services/in_app_notification_service.dart';
import '../services/notification_navigation_service.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

/// Listens for [InAppNotificationService] events and shows a top banner.
class InAppNotificationHost extends StatefulWidget {
  const InAppNotificationHost({super.key, required this.child});

  final Widget child;

  @override
  State<InAppNotificationHost> createState() => _InAppNotificationHostState();
}

class _InAppNotificationHostState extends State<InAppNotificationHost> {
  StreamSubscription<InAppNotificationEvent>? _sub;
  InAppNotificationEvent? _current;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _sub = InAppNotificationService.instance.stream.listen(_show);
  }

  void _show(InAppNotificationEvent event) {
    _hideTimer?.cancel();
    setState(() => _current = event);
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _current = null);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_current != null)
          Positioned(
            top: MediaQuery.of(context).padding.top + AppSpacing.smallGap,
            left: AppSpacing.screenPadding,
            right: AppSpacing.screenPadding,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(AppRadii.medium),
              color: AppColors.textPrimary,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadii.medium),
                onTap: () {
                  final convId = _current!.conversationId;
                  setState(() => _current = null);
                  if (convId != null) {
                    NotificationNavigationService.instance.openConversation(convId);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.mediumGap,
                    vertical: AppSpacing.smallGap + 4,
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.notifications_none, color: AppColors.textInverse, size: 20),
                      const SizedBox(width: AppSpacing.smallGap),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _current!.title,
                              style: AppTypography.subtitle.copyWith(color: AppColors.textInverse),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              _current!.body,
                              style: AppTypography.caption.copyWith(color: AppColors.textMuted),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: AppColors.textMuted, size: 18),
                        onPressed: () => setState(() => _current = null),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
