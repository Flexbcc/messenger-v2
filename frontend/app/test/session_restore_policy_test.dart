import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/services/api_client.dart';
import 'package:messenger_app/services/session_restore_policy.dart';

void main() {
  const policy = SessionRestorePolicy();

  test(
    'explicit authentication and missing-device responses clear session',
    () {
      for (final status in [401, 403, 404]) {
        final error = ApiException(status, 'rejected');
        expect(policy.shouldClear(error), isTrue, reason: 'HTTP $status');
        expect(policy.shouldRetain(error), isFalse, reason: 'HTTP $status');
      }
    },
  );

  test('temporary HTTP failures retain local login and identity', () {
    for (final status in [408, 425, 429, 500, 502, 503, 504]) {
      final error = ApiException(status, 'temporary');
      expect(policy.shouldClear(error), isFalse, reason: 'HTTP $status');
      expect(policy.shouldRetain(error), isTrue, reason: 'HTTP $status');
    }
  });

  test('transport, timeout and parse failures retain local login', () {
    final errors = <Object>[
      TimeoutException('home timeout'),
      StateError('connection refused'),
      const FormatException('temporary malformed upstream response'),
    ];
    for (final error in errors) {
      expect(policy.shouldClear(error), isFalse, reason: '$error');
      expect(policy.shouldRetain(error), isTrue, reason: '$error');
    }
  });
}
