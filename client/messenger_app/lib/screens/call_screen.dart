import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../calls/active_call.dart';
import '../calls/call_signal.dart';
import '../state/app_controller.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';
import '../utils/call_format.dart';
import '../widgets/avatar.dart';

/// Full-screen call UI, shown by MessengerApp whenever
/// `AppController.currentCall` is non-null and not minimized.
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key});

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;
  Object? _wiredMedia;
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    _initRenderers();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    if (!mounted) return;
    setState(() => _renderersReady = true);
    _attachIfNeeded();
  }

  void _attachIfNeeded() {
    final media = ref.read(appControllerProvider).currentCall?.media;
    if (!_renderersReady || media == null || identical(media, _wiredMedia)) return;
    _wiredMedia = media;
    _localRenderer.srcObject = media.localStream;
    _remoteRenderer.srcObject = media.remoteStream;
    media.onRemoteStream = (stream) {
      _remoteRenderer.srcObject = stream;
      if (media.onHold) media.setOnHold(true);
      if (mounted) setState(() {});
    };
  }

  void _toggleMute() {
    final media = ref.read(appControllerProvider).currentCall?.media;
    if (media == null) return;
    media.setMuted(!media.isMuted);
    setState(() {});
  }

  void _toggleHold() {
    final media = ref.read(appControllerProvider).currentCall?.media;
    if (media == null) return;
    media.setOnHold(!media.onHold);
    setState(() {});
  }

  void _minimize() {
    ref.read(appControllerProvider).setCallUiMinimized(true);
  }

  Duration _elapsed(ActiveCall call) {
    final start = call.answeredAt ?? call.startedAt;
    return DateTime.now().difference(start);
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final call = controller.currentCall;
    if (call == null || controller.callUiMinimized) return const SizedBox.shrink();
    _attachIfNeeded();

    final peerName = controller.labelFor(call.peerUserId);
    final showVideo = call.kind == CallKind.video && call.media != null;
    final media = call.media;

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
                child: showVideo
                    ? _VideoLayer(localRenderer: _localRenderer, remoteRenderer: _remoteRenderer)
                    : _AudioLayer(peerName: peerName),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _StatusHeader(peerName: peerName, call: call, elapsed: _elapsed(call)),
              ),
              if (call.answered)
                Positioned(
                  top: AppSpacing.sectionGap,
                  right: AppSpacing.screenPadding,
                  child: IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down, color: AppColors.textInverse, size: 32),
                    tooltip: 'Свернуть звонок',
                    onPressed: _minimize,
                  ),
                ),
              Positioned(
                bottom: AppSpacing.sectionGap * 2,
                left: 0,
                right: 0,
                child: _Controls(
                  controller: controller,
                  call: call,
                  muted: media?.isMuted ?? false,
                  onHold: media?.onHold ?? false,
                  onToggleMute: _toggleMute,
                  onToggleHold: _toggleHold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.peerName, required this.call, required this.elapsed});
  final String peerName;
  final ActiveCall call;
  final Duration elapsed;

  String get _statusText {
    if (!call.answered) return call.outgoing ? 'Звоним…' : 'Входящий звонок';
    if (call.waitingForNetwork) return 'Ожидание сети…';
    if (call.media?.onHold == true) return 'На удержании';
    return call.kind == CallKind.video ? 'Видеозвонок' : 'Разговор';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sectionGap),
      child: Column(
        children: [
          Text(peerName, style: AppTypography.title.copyWith(color: AppColors.textInverse)),
          const SizedBox(height: 4),
          Text(
            _statusText,
            style: AppTypography.secondary.copyWith(
              color: call.waitingForNetwork ? AppColors.warningYellow : AppColors.textMuted,
            ),
          ),
          if (call.answered) ...[
            const SizedBox(height: 8),
            Text(
              formatCallDuration(elapsed),
              style: AppTypography.largeTitle.copyWith(color: AppColors.textInverse, fontSize: 28),
            ),
          ],
        ],
      ),
    );
  }
}

class _AudioLayer extends StatelessWidget {
  const _AudioLayer({required this.peerName});
  final String peerName;

  @override
  Widget build(BuildContext context) {
    return Center(child: AppAvatar(label: peerName, size: AppAvatarSize.large));
  }
}

class _VideoLayer extends StatelessWidget {
  const _VideoLayer({required this.localRenderer, required this.remoteRenderer});
  final RTCVideoRenderer localRenderer;
  final RTCVideoRenderer remoteRenderer;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.35)),
            child: RTCVideoView(remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
          ),
        ),
        Positioned(
          top: AppSpacing.mediumGap + 48,
          right: AppSpacing.mediumGap,
          width: 110,
          height: 150,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.medium),
            child: RTCVideoView(localRenderer, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
          ),
        ),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.controller,
    required this.call,
    required this.muted,
    required this.onHold,
    required this.onToggleMute,
    required this.onToggleHold,
  });

  final AppController controller;
  final ActiveCall call;
  final bool muted;
  final bool onHold;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleHold;

  @override
  Widget build(BuildContext context) {
    if (!call.answered && !call.outgoing) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _RoundButton(icon: Icons.call_end, color: AppColors.dangerRed, label: 'Отклонить', onTap: controller.rejectCall),
          _RoundButton(icon: Icons.call, color: AppColors.successGreen, label: 'Ответить', onTap: controller.answerCall),
        ],
      );
    }
    if (!call.answered) {
      return Center(
        child: _RoundButton(icon: Icons.call_end, color: AppColors.dangerRed, label: 'Отменить', onTap: controller.cancelCall),
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
          icon: onHold ? Icons.play_arrow : Icons.pause,
          color: onHold ? AppColors.accentBlue.withValues(alpha: 0.35) : AppColors.surfaceDark,
          label: onHold ? 'Продолжить' : 'Удержание',
          onTap: onToggleHold,
        ),
        _RoundButton(icon: Icons.call_end, color: AppColors.dangerRed, label: 'Завершить', onTap: controller.endCall),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

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
