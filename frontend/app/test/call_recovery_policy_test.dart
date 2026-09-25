import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/calls/call_media_controller.dart';
import 'package:messenger_app/calls/call_recovery_policy.dart';

void main() {
  test('disconnect starts exactly one recovery attempt', () {
    expect(
      CallRecoveryPolicy.decide(
        state: MediaConnectionState.disconnected,
        waitingForNetwork: false,
      ),
      CallRecoveryDecision.startRecovery,
    );
    expect(
      CallRecoveryPolicy.decide(
        state: MediaConnectionState.disconnected,
        waitingForNetwork: true,
      ),
      CallRecoveryDecision.ignore,
    );
  });

  test('connected clears only an active recovery state', () {
    expect(
      CallRecoveryPolicy.decide(
        state: MediaConnectionState.connected,
        waitingForNetwork: true,
      ),
      CallRecoveryDecision.recovered,
    );
    expect(
      CallRecoveryPolicy.decide(
        state: MediaConnectionState.connected,
        waitingForNetwork: false,
      ),
      CallRecoveryDecision.ignore,
    );
  });

  test('failed terminates while transitional and local close are ignored', () {
    expect(
      CallRecoveryPolicy.decide(
        state: MediaConnectionState.failed,
        waitingForNetwork: false,
      ),
      CallRecoveryDecision.terminate,
    );
    for (final state in [
      MediaConnectionState.connecting,
      MediaConnectionState.closed,
    ]) {
      expect(
        CallRecoveryPolicy.decide(state: state, waitingForNetwork: true),
        CallRecoveryDecision.ignore,
      );
    }
  });
}
