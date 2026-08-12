import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../calls/active_call.dart';
import '../calls/call_signal.dart';
import '../state/app_controller.dart';
import '../theme/spacing.dart';
import '../widgets/call_stage.dart';

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
    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() => _renderersReady = true);
    _attachIfNeeded();
  }

  void _attachIfNeeded() {
    final media = ref.read(appControllerProvider).currentCall?.media;
    if (!_renderersReady || media == null || identical(media, _wiredMedia)) {
      return;
    }
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

  Future<void> _toggleSpeaker() async {
    final media = ref.read(appControllerProvider).currentCall?.media;
    if (media == null) return;
    await media.setSpeaker(!media.isSpeakerOn);
    if (mounted) setState(() {});
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
    if (call == null || controller.callUiMinimized) {
      return const SizedBox.shrink();
    }
    _attachIfNeeded();

    final peerName = controller.labelFor(call.peerUserId);
    final media = call.media;
    final liveVideo =
        call.kind == CallKind.video &&
        call.answered &&
        media != null &&
        _renderersReady;

    return CallStage(
      peerName: peerName,
      kind: call.kind,
      outgoing: call.outgoing,
      answered: call.answered,
      elapsed: _elapsed(call),
      waitingForNetwork: call.waitingForNetwork,
      muted: media?.isMuted ?? false,
      speakerOn: media?.isSpeakerOn ?? false,
      onHold: media?.onHold ?? false,
      showVideoPlaceholder:
          call.kind == CallKind.video && call.answered && !liveVideo,
      background: liveVideo
          ? _VideoLayer(
              localRenderer: _localRenderer,
              remoteRenderer: _remoteRenderer,
            )
          : null,
      onToggleMute: _toggleMute,
      onToggleSpeaker: _toggleSpeaker,
      onToggleHold: _toggleHold,
      onReject: controller.rejectCall,
      onAnswer: controller.answerCall,
      onCancel: controller.cancelCall,
      onEnd: controller.endCall,
      onMinimize: _minimize,
    );
  }
}

class _VideoLayer extends StatelessWidget {
  const _VideoLayer({
    required this.localRenderer,
    required this.remoteRenderer,
  });
  final RTCVideoRenderer localRenderer;
  final RTCVideoRenderer remoteRenderer;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
            ),
            child: RTCVideoView(
              remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          ),
        ),
        Positioned(
          top: AppSpacing.mediumGap + 48,
          right: AppSpacing.mediumGap,
          width: 110,
          height: 150,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: RTCVideoView(
              localRenderer,
              mirror: true,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          ),
        ),
      ],
    );
  }
}
