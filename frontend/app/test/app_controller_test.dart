import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/state/app_controller.dart';

void main() {
  group('AppController.labelFor', () {
    test('falls back to a truncated id when no display name is cached', () {
      final controller = AppController();
      expect(controller.labelFor('123456789abcdef'), '12345678…');
    });

    test('does not throw for ids shorter than the truncation length', () {
      final controller = AppController();
      expect(controller.labelFor('32'), '32…');
      expect(controller.labelFor(''), '…');
    });
  });

  group('device-link QR payload', () {
    test('parses only the versioned OUO device-link payload', () {
      final controller = AppController();
      final parsed = controller.parseDeviceLinkPayload(
        '{"kind":"ouo_device_link","v":1,"id":"123e4567-e89b-42d3-a456-426614174000","secret":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}',
      );
      expect(parsed['link_id'], '123e4567-e89b-42d3-a456-426614174000');
      expect(parsed['secret'], 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
    });

    test('rejects a profile or arbitrary QR', () {
      final controller = AppController();
      expect(
        () => controller.parseDeviceLinkPayload(
          '{"kind":"profile_qr","v":1,"id":"user"}',
        ),
        throwsFormatException,
      );
    });
  });
}
