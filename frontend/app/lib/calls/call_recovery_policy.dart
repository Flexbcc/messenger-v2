import 'call_media_controller.dart';

/// Pure decision layer for transient WebRTC connection changes.
///
/// Keeping this separate from timers and `RTCPeerConnection` makes the
/// reconnect contract exhaustive and testable without requesting a real
/// microphone in unit tests.
enum CallRecoveryDecision { ignore, recovered, startRecovery, terminate }

abstract final class CallRecoveryPolicy {
  static CallRecoveryDecision decide({
    required MediaConnectionState state,
    required bool waitingForNetwork,
  }) {
    return switch (state) {
      MediaConnectionState.connected =>
        waitingForNetwork
            ? CallRecoveryDecision.recovered
            : CallRecoveryDecision.ignore,
      MediaConnectionState.disconnected =>
        waitingForNetwork
            ? CallRecoveryDecision.ignore
            : CallRecoveryDecision.startRecovery,
      MediaConnectionState.failed => CallRecoveryDecision.terminate,
      MediaConnectionState.connecting ||
      MediaConnectionState.closed => CallRecoveryDecision.ignore,
    };
  }
}
