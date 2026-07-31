import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/models/settings_catalog.dart';

void main() {
  SettingDef setting(Map<String, dynamic> data) => SettingDef.fromJson(
        jsonDecode(jsonEncode(data)) as Map<String, dynamic>,
      );

  test('catalog text validation enforces length and pattern', () {
    final username = setting({
      'id': 'profile.username',
      'title': 'Username',
      'type': 'text',
      'data': {
        'minLength': 3,
        'maxLength': 32,
        'pattern': r'^[a-zA-Z][a-zA-Z0-9_]{2,31}$',
      },
    });

    expect(username.validateInput('ab', number: false), isNotNull);
    expect(username.validateInput('1invalid', number: false), isNotNull);
    expect(username.validateInput('valid_user', number: false), isNull);
  });

  test('catalog validates phone, email, and numeric bounds', () {
    final phone = setting({
      'id': 'identity.phone',
      'title': 'Телефон',
      'type': 'text',
      'format': 'phone',
      'data': {'pattern': r'^\+[1-9]\d{7,14}$'},
    });
    final email = setting({
      'id': 'identity.email',
      'title': 'Почта',
      'type': 'text',
      'format': 'email',
    });
    final count = setting({
      'id': 'test.count',
      'title': 'Количество',
      'type': 'number',
      'data': {'minimum': 1, 'maximum': 10},
    });

    expect(phone.validateInput('89991234567', number: false), isNotNull);
    expect(phone.validateInput('+79991234567', number: false), isNull);
    expect(email.validateInput('not-an-email', number: false), isNotNull);
    expect(email.validateInput('a@example.org', number: false), isNull);
    expect(count.validateInput('0', number: true), isNotNull);
    expect(count.validateInput('5', number: true), isNull);
  });
}
