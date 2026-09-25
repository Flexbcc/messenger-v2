import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/core/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui_screenshots/scenes.dart';
import 'ui_screenshots/states_manifest.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final entry in <(String, ThemeData, Size, double)>[
    ('dark standard', AppTheme.dark(), const Size(390, 844), 1),
    ('light standard', AppTheme.light(), const Size(390, 844), 1),
    ('dark compact', AppTheme.dark(), const Size(320, 640), 1),
    ('light large text', AppTheme.light(), const Size(390, 844), 1.3),
  ]) {
    testWidgets('all UI scenes render in ${entry.$1}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = entry.$3 * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final state in kScreenshotStates.where((state) => !state.skipped)) {
        await tester.pumpWidget(
          MaterialApp(
            theme: entry.$2,
            home: MediaQuery(
              data: MediaQueryData(
                size: entry.$3,
                textScaler: TextScaler.linear(entry.$4),
              ),
              child: buildScreenshotScene(state),
            ),
          ),
        );
        await tester.pump();
        expect(
          tester.takeException(),
          isNull,
          reason: '${state.fileStem} failed in ${entry.$1}',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    });
  }
}
