import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/screens/private_mode/private_feature_route.dart';
import 'package:messenger_app/security/private_feature_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('protected destination is not built without both PINs', (
    tester,
  ) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    var destinationBuilt = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              privateSecretRoute(
                (_) {
                  destinationBuilt = true;
                  return const Scaffold(body: Text('sensitive destination'));
                },
                accessLoader: () async => const PrivateFeatureAccess(
                  hasPrimaryPin: false,
                  hasDecoyPin: false,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(destinationBuilt, isFalse);
    expect(find.text('sensitive destination'), findsNothing);
    expect(find.text('Защищённый раздел'), findsOneWidget);
  });

  testWidgets('protected destination is built after both PINs', (tester) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    var destinationBuilt = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              privateSecretRoute(
                (_) {
                  destinationBuilt = true;
                  return const Scaffold(body: Text('sensitive destination'));
                },
                accessLoader: () async => const PrivateFeatureAccess(
                  hasPrimaryPin: true,
                  hasDecoyPin: true,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(destinationBuilt, isTrue);
    expect(find.text('sensitive destination'), findsOneWidget);
  });
}
