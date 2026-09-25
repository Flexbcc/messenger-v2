import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/services/node_owner/owner_device_certificate.dart';

void main() {
  const fixture =
      '{"device_id":"11111111-1111-4111-8111-111111111111","device_public_key":"Kay64UG8yvCyLhqU000LxzYeUm0L_hLIl5S8kyKWbdc=","issued_at":"2026-09-24T12:00:00Z","node_id":"ouo-node-v1-kzdvvj2umnduyauf35o36k6kw462mujvra46tn3uqgzovmihocga","node_root_public_key":"A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=","object_version":1,"protocol_version":"ouo-owner-device/1","role":"owner","serial":"22222222-2222-4222-8222-222222222222","signature":"h0z4uCNeQc9uyPA-5UmbHdHizYCjiWxc4MqPk2ZqnFjL2_pIBNwFa1DL9OQqgQGtCm_R7KR3Ge4i1CYS0e9LAw==","signature_algorithm":"Ed25519","valid_until":"2026-10-24T12:00:00Z"}';

  test('Flutter verifies certificate produced by Python node', () async {
    final value = Map<String, dynamic>.from(jsonDecode(fixture) as Map);
    final certificate = await OwnerDeviceCertificate.parseAndVerify(
      value,
      expectedNodeId:
          'ouo-node-v1-kzdvvj2umnduyauf35o36k6kw462mujvra46tn3uqgzovmihocga',
      expectedRootPublicKey: 'A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=',
      expectedDevicePublicKey: 'Kay64UG8yvCyLhqU000LxzYeUm0L_hLIl5S8kyKWbdc=',
      now: DateTime.utc(2026, 9, 25),
    );
    expect(certificate.serial, '22222222-2222-4222-8222-222222222222');
  });

  test('tampered role or wrong node is rejected', () async {
    final tampered = Map<String, dynamic>.from(jsonDecode(fixture) as Map)
      ..['role'] = 'viewer';
    await expectLater(
      OwnerDeviceCertificate.parseAndVerify(
        tampered,
        expectedNodeId:
            'ouo-node-v1-kzdvvj2umnduyauf35o36k6kw462mujvra46tn3uqgzovmihocga',
        expectedRootPublicKey: 'A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=',
        expectedDevicePublicKey: 'Kay64UG8yvCyLhqU000LxzYeUm0L_hLIl5S8kyKWbdc=',
        now: DateTime.utc(2026, 9, 25),
      ),
      throwsFormatException,
    );
  });
}
