import 'package:flutter/material.dart';

import '../calls/call_signal.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';
import '../utils/call_format.dart';
import 'avatar.dart';

/// Presentational full-screen call UI (no WebRTC). Used by [CallScreen] and
/// the screenshot harness.
class CallStage extends StatelessWidget {
  const CallStage({
    super.key,
    required this.peerName,
    required this.kind,
    required this.outgoing,
    required this.answered,
    this.elapsed = Duration.zero,
    this.waitingForNetwork = false,
    this.muted = false,
    this.speakerOn = false,
    this.onHold = false,
    this.showVideoPlaceholder = false,
    this.background,
    this.onToggleMute,
    this.onToggleSpeaker,
    this.onToggleHold,
    this.onReject,
    this.onAnswer,
    this.onCancel,
    this.onEnd,
    this.onMinimize,
  });

  final String peerName;
  final CallKind kind;
  final bool outgoing;
  final bool answered;
  final Duration elapsed;
  final bool waitingForNetwork;
  final bool muted;
  final bool speakerOn;
  final bool onHold;
  final bool showVideoPlaceholder;
  final Widget? background;
  final VoidCallback? onToggleMute;
  final VoidCallback? onToggleSpeaker;
  final VoidCallback? onToggleHold;
  final VoidCallback? onReject;
  final VoidCallback? onAnswer;
  final VoidCallback? onCancel;
  final VoidCallback? onEnd;
  final VoidCallback? onMinimize;

  String get statusText {
    if (!answered) return outgoing ? 'Звоним…' : 'Входящий звонок';
    if (waitingForNetwork) return 'Ожидание сети…';
    if (onHold) return 'На удержании';
    if (speakerOn) return 'Громкая связь';
    return kind == CallKind.video ? 'Видеозвонок' : 'Разговор';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.callBackdropTop, AppColors.callBackdropBottom],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: background ??
                    (showVideoPlaceholder
                        ? const _VideoPlaceholder()
                        : Center(child: AppAvatar(label: peerName, size: AppAvatarSize.large))),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sectionGap),
                  child: Column(
                    children: [
                      Text(peerName, style: AppTypography.title.copyWith(color: AppColors.textInverse)),
                      const SizedBox(height: 4),
                      Text(
                        statusText,
                        style: AppTypography.secondary.copyWith(
                          color: waitingForNetwork ? AppColors.warningYellow : AppColors.textMuted,
                        ),
                      ),
                      if (answered) ...[
                        const SizedBox(height: 8),
                        Text(
                          formatCallDuration(elapsed),
                          style: AppTypography.largeTitle.copyWith(color: AppColors.textInverse, fontSize: 28),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (answered && onMinimize != null)
                Positioned(
                  top: AppSpacing.sectionGap,
                  right: AppSpacing.screenPadding,
                  child: IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down, color: AppColors.textInverse, size: 32),
                    tooltip: 'Свернуть звонок',
                    onPressed: onMinimize,
                  ),
                ),
              Positioned(
                bottom: AppSpacing.sectionGap * 2,
                left: 0,
                right: 0,
                child: _CallControls(
                  answered: answered,
                  outgoing: outgoing,
                  muted: muted,
                  speakerOn: speakerOn,
                  onHold: onHold,
                  onToggleMute: onToggleMute,
                  onToggleSpeaker: onToggleSpeaker,
                  onToggleHold: onToggleHold,
                  onReject: onReject,
                  onAnswer: onAnswer,
                  onCancel: onCancel,
                  onEnd: onEnd,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Brief full-screen “call ended” frame for product + screenshots.
class CallEndedOverlay extends StatelessWidget {
  const CallEndedOverlay({super.key, required this.peerName, this.onDismiss});

  final String peerName;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.call_end, color: AppColors.textInverse, size: 48),
              const SizedBox(height: 16),
              Text('Звонок завершён', style: AppTypography.title.copyWith(color: AppColors.textInverse)),
              const SizedBox(height: 8),
              Text(peerName, style: AppTypography.secondary.copyWith(color: AppColors.textMuted)),
              if (onDismiss != null) ...[
                const SizedBox(height: 24),
                TextButton(
                  onPressed: onDismiss,
                  child: const Text('Закрыть', style: TextStyle(color: AppColors.textInverse)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.45),
      child: const Center(
        child: Icon(Icons.videocam, color: AppColors.textMuted, size: 64),
      ),
    );
  }
}

class _CallControls extends StatelessWidget {
  const _CallControls({
    required this.answered,
    required this.outgoing,
    required this.muted,
    required this.speakerOn,
    required this.onHold,
    this.onToggleMute,
    this.onToggleSpeaker,
    this.onToggleHold,
    this.onReject,
    this.onAnswer,
    this.onCancel,
    this.onEnd,
  });

  final bool answered;
  final bool outgoing;
  final bool muted;
  final bool speakerOn;
  final bool onHold;
  final VoidCallback? onToggleMute;
  final VoidCallback? onToggleSpeaker;
  final VoidCallback? onToggleHold;
  final VoidCallback? onReject;
  final VoidCallback? onAnswer;
  final VoidCallback? onCancel;
  final VoidCallback? onEnd;

  @override
  Widget build(BuildContext context) {
    if (!answered && !outgoing) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _RoundButton(icon: Icons.call_end, color: AppColors.dangerRed, label: 'Отклонить', onTap: onReject),
          _RoundButton(icon: Icons.call, color: AppColors.successGreen, label: 'Ответить', onTap: onAnswer),
        ],
      );
    }
    if (!answered) {
      return Center(
        child: _RoundButton(icon: Icons.call_end, color: AppColors.dangerRed, label: 'Отменить', onTap: onCancel),
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RoundButton(
          icon: muted ? Icons.mic_off : Icons.mic,
          color: muted ? AppColors.warningYellow.withValues(alpha: 0.25) : AppColors.surfaceDark,
          label: muted ? 'Вкл. звук' : 'Микрофон',
          onTap: onToggleMute,
        ),
        _RoundButton(
          icon: speakerOn ? Icons.volume_up : Icons.volume_down,
          color: speakerOn ? AppColors.accentBlue.withValues(alpha: 0.35) : AppColors.surfaceDark,
          label: speakerOn ? 'Динамик' : 'Тихо',
          onTap: onToggleSpeaker,
        ),
        _RoundButton(
          icon: onHold ? Icons.play_arrow : Icons.pause,
          color: onHold ? AppColors.accentBlue.withValues(alpha: 0.35) : AppColors.surfaceDark,
          label: onHold ? 'Продолжить' : 'Удержание',
          onTap: onToggleHold,
        ),
        _RoundButton(icon: Icons.call_end, color: AppColors.dangerRed, label: 'Завершить', onTap: onEnd),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.color,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          iconSize: 28,
          padding: const EdgeInsets.all(18),
          style: IconButton.styleFrom(backgroundColor: color, shape: const CircleBorder()),
          icon: Icon(icon, color: AppColors.textInverse),
          onPressed: onTap,
        ),
        const SizedBox(height: 6),
        Text(label, style: AppTypography.caption.copyWith(color: AppColors.textMuted, fontSize: 11)),
      ],
    );
  }
}
