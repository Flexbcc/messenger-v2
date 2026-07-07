import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../calls/active_call.dart';
import '../calls/call_signal.dart';
import '../state/app_controller.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';
import '../utils/call_format.dart';
import '../widgets/avatar.dart';

/// Compact in-call bar shown when the user minimizes the full-screen call UI.
class CallMinimizedBar extends ConsumerStatefulWidget {
  const CallMinimizedBar({super.key});

  @override
  ConsumerState<CallMinimizedBar> createState() => _CallMinimizedBarState();
}

class _CallMinimizedBarState extends ConsumerState<CallMinimizedBar> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _status(ActiveCall call) {
    if (!call.answered) return call.outgoing ? 'Звоним…' : 'Входящий';
    if (call.waitingForNetwork) return 'Ожидание сети…';
    if (call.media?.onHold == true) return 'На удержании';
    return formatCallDuration(_elapsed(call));
  }

  Duration _elapsed(ActiveCall call) {
    final start = call.answeredAt ?? call.startedAt;
    return DateTime.now().difference(start);
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final call = controller.currentCall;
    if (call == null) return const SizedBox.shrink();

    final peerName = controller.labelFor(call.peerUserId);
    final top = MediaQuery.of(context).padding.top;

    return Positioned(
      top: top,
      left: AppSpacing.screenPadding,
      right: AppSpacing.screenPadding,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(AppRadii.medium),
        color: AppColors.callBackdropTop,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadii.medium),
          onTap: () => controller.setCallUiMinimized(false),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.mediumGap, vertical: AppSpacing.smallGap),
            child: Row(
              children: [
                AppAvatar(label: peerName, size: AppAvatarSize.small),
                const SizedBox(width: AppSpacing.smallGap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(peerName, style: AppTypography.subtitle.copyWith(color: AppColors.textInverse), maxLines: 1),
                      Text(
                        _status(call),
                        style: AppTypography.caption.copyWith(color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
                Icon(
                  call.kind == CallKind.video ? Icons.videocam : Icons.call,
                  color: AppColors.successGreen,
                  size: 20,
                ),
                IconButton(
                  icon: const Icon(Icons.call_end, color: AppColors.dangerRed),
                  onPressed: call.answered ? controller.endCall : (call.outgoing ? controller.cancelCall : controller.rejectCall),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
