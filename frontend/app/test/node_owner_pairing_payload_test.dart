import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/services/node_owner/node_owner_pairing_payload.dart';

void main() {
  Map<String, dynamic> payload() => {
    'kind': 'ouo_node_owner_pair',
    'version': 1,
    'protocol_version': 'ouo-owner-pair/1',
    'node_id':
        'ouo-node-v1-kzdvvj2umnduyauf35o36k6kw462mujvra46tn3uqgzovmihocga',
    'node_root_public_key': 'A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=',
    'management_endpoints': ['https://100.64.0.2:9443'],
    'management_ca_fingerprint': 'sha256:aa',
    'pairing_id': '11111111-1111-4111-8111-111111111111',
    'pairing_secret': List.filled(43, 'x').join(),
    'role': 'owner',
    'expires_at': '2026-09-24T12:05:00Z',
  };

  test('parses a node-bound short-lived pairing QR', () {
    final parsed = NodeOwnerPairingPayload.parse(
      jsonEncode(payload()),
      now: DateTime.utc(2026, 9, 24, 12, 1),
    );
    expect(parsed.role, 'owner');
    expect(parsed.managementEndpoints.single.scheme, 'https');
  });

  test('rejects wrong NodeID and plaintext remote endpoint', () {
    final wrongNode = payload()..['node_id'] = 'ouo-node-v1-wrong';
    expect(
      () => NodeOwnerPairingPayload.parse(
        jsonEncode(wrongNode),
        now: DateTime.utc(2026, 9, 24, 12, 1),
      ),
      throwsFormatException,
    );
    final unsafe = payload()
      ..['management_endpoints'] = ['http://192.168.1.10:9443'];
    expect(
      () => NodeOwnerPairingPayload.parse(
        jsonEncode(unsafe),
        now: DateTime.utc(2026, 9, 24, 12, 1),
      ),
      throwsFormatException,
    );
  });
}
