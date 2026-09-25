import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/models/contact_trust.dart';
import 'package:messenger_app/services/contact_runtime_service.dart';

void main() {
  test('default trust is seeded through the service, not its read-only view', () {
    final contacts = ContactRuntimeService();

    expect(contacts.trustLevels['peer'], isNull);
    contacts.ensureDefaultTrust('peer');
    expect(contacts.trustLevels['peer'], TrustLevel.normal);
    expect(
      () => contacts.trustLevels['other'] = TrustLevel.normal,
      throwsUnsupportedError,
    );
  });
}
