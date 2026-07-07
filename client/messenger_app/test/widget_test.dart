// Smoke test: app boots to the onboarding screen when no session is stored.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:messenger_app/main.dart';

void main() {
  testWidgets('App boots and shows onboarding when logged out', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: MessengerApp()));
    await tester.pump(); // let the splash frame render
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Создать аккаунт'), findsOneWidget);
  });
}
