import 'dart:async';

import 'call_media_controller.dart';
import 'call_signal.dart';

/// In-memory state for the one call the app can be in at a time — no group
/// calls, no multi-device fan-out for MVP (see spec/0303_CALLS.md → Не
/// входит в MVP). Populated by AppController's call methods and incoming
/// signal handling; read by the UI layer (next step).
class ActiveCall {
  ActiveCall({
    required this.callId,
    required this.peerUserId,
    required this.kind,
    required this.outgoing,
    this.answered = false,
    this.remoteSdp,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  final String callId;
  final String peerUserId;
  final CallKind kind;
  final DateTime startedAt;

  /// True if we sent the `call_offer` (we're calling them); false if we
  /// received it (they're calling us).
  final bool outgoing;

  /// True once `call_answer` has been sent (incoming call) or received
  /// (outgoing call). Before that, the call is only "ringing".
  bool answered;

  /// When the call became active (both sides connected signaling-wise).
  DateTime? answeredAt;

  /// The peer's SDP: their offer (incoming — filled immediately) or their
  /// answer (outgoing — filled once received).
  String? remoteSdp;

  /// The real WebRTC connection. Null only during the brief incoming-call
  /// ringing window before answerCall() creates it — the caller side
  /// always has one from the moment startCall() returns.
  CallMediaController? media;

  /// True while the ICE connection is `disconnected` — a transient network
  /// hiccup, not a hangup (see spec/0303_CALLS.md → Устойчивость
  /// соединения). Deliberately separate from `answered`/`outgoing`, which
  /// describe the call's signaling phase, not its current media health.
  bool waitingForNetwork = false;

  /// Pending "declare this call really dead" timer while
  /// [waitingForNetwork] is true — cancelled if the connection recovers.
  Timer? reconnectTimer;

  /// ICE candidates that arrived before [media] existed (callee side,
  /// before answerCall() was called) — flushed into it once created.
  final List<Map<String, dynamic>> pendingRemoteIceCandidates = [];
}
