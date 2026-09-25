import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/services/node_owner/node_owner_transport_io.dart';

void main() {
  test('normalizes colon-separated SHA-256 certificate fingerprints', () {
    const plain =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    const separated =
        '01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:'
        '01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF';
    expect(normalizeSha256Fingerprint('sha256:$separated'), plain);
    expect(
      () => normalizeSha256Fingerprint('sha256:not-a-fingerprint'),
      throwsFormatException,
    );
  });

  test('computes stable SHA-256 DER fingerprint', () {
    expect(
      sha256Fingerprint(const [1, 2, 3]),
      '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
    );
  });
}
