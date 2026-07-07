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
}
