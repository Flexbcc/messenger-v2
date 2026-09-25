import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/models/connection_probe_result.dart';

ConnectionProbeResult endpoint(
  String id, {
  bool reachable = true,
  bool clientDirect = true,
}) => ConnectionProbeResult(
  id: id,
  label: id,
  url: 'https://$id.example',
  reachable: reachable,
  clientDirect: clientDirect,
);

ConnectionStatusSnapshot snapshot(
  List<ConnectionProbeResult> endpoints, {
  bool websocketConnected = true,
}) => ConnectionStatusSnapshot(
  probedAt: DateTime.utc(2026, 9, 24),
  endpoints: endpoints,
  websocketConnected: websocketConnected,
);

void main() {
  test(
    'one failed Discovery keeps a three-source quorum and messaging online',
    () {
      final result = snapshot([
        endpoint('home'),
        endpoint('gateway'),
        endpoint('discovery-1'),
        endpoint('discovery-2', reachable: false),
        endpoint('discovery-3'),
      ]);

      expect(result.reachableDiscoveryCount, 2);
      expect(result.requiredDiscoveryCount, 2);
      expect(result.discoveryQuorumReachable, isTrue);
      expect(result.clientReachable, isTrue);
      expect(result.allClientServicesReachable, isFalse);
    },
  );

  test('Home or WebSocket outage makes messaging unavailable', () {
    final homeDown = snapshot([
      endpoint('home', reachable: false),
      endpoint('discovery-1'),
    ]);
    final websocketDown = snapshot([
      endpoint('home'),
      endpoint('discovery-1'),
    ], websocketConnected: false);

    expect(homeDown.clientReachable, isFalse);
    expect(websocketDown.clientReachable, isFalse);
  });

  test(
    'two failed Discovery sources lose quorum without stopping Home session',
    () {
      final result = snapshot([
        endpoint('home'),
        endpoint('discovery-1'),
        endpoint('discovery-2', reachable: false),
        endpoint('discovery-3', reachable: false),
      ]);

      expect(result.discoveryQuorumReachable, isFalse);
      expect(result.clientReachable, isTrue);
    },
  );
}
