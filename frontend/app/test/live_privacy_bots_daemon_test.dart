@TestOn('vm')
@Timeout(Duration(days: 1))
@Tags(['integration', 'live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/live_privacy_bots.dart' as daemon;

void main() {
  test(
    'live encrypted privacy bots',
    () async {
      final target = Platform.environment['TARGET_USER_ID'];
      await daemon.main(['--target=$target']);
    },
    skip:
        Platform.environment['TARGET_USER_ID'] == null ||
            Platform.environment['TARGET_USER_ID']!.isEmpty
        ? 'Requires TARGET_USER_ID and a reachable live backend'
        : false,
  );
}
