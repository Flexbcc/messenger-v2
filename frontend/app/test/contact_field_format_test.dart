import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/utils/contact_field_format.dart';

void main() {
  test('normalizes common Russian phone input to E.164', () {
    expect(normalizePhoneNumber('8 (999) 123-45-67'), '+79991234567');
    expect(normalizePhoneNumber('999 123 45 67'), '+79991234567');
    expect(normalizePhoneNumber('+44 20 7946 0958'), '+442079460958');
  });

  test('formats Russian phone for editing', () {
    expect(formatPhoneNumber('+79991234567'), '+7 (999) 123-45-67');
  });

  test('validates practical email addresses', () {
    expect(isValidEmailAddress('name@example.com'), isTrue);
    expect(isValidEmailAddress('first.last+tag@example.co.uk'), isTrue);
    expect(isValidEmailAddress('name..double@example.com'), isFalse);
    expect(isValidEmailAddress('name@localhost'), isFalse);
  });
}
