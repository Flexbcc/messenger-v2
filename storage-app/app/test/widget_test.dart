import 'package:flutter_test/flutter_test.dart';
import 'package:storage_app/services/app_settings.dart';

void main() {
  test('AppSettings default port is 7345', () {
    const s = AppSettings();
    expect(s.port, 7345);
    expect(s.isConfigured, isFalse);
  });
}
