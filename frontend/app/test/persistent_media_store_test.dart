import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/services/persistent_media_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory applicationSupportDirectory;

  setUp(() async {
    applicationSupportDirectory = await Directory.systemTemp.createTemp(
      'ouo-media-store-test-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => applicationSupportDirectory.path,
        );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (await applicationSupportDirectory.exists()) {
      await applicationSupportDirectory.delete(recursive: true);
    }
  });

  test('ciphertext is scoped by account and can be cleared', () async {
    final store = PersistentMediaStore.instance;
    final mediaId = 'a' * 64;
    await store.clearUser('media-user-a');
    await store.clearUser('media-user-b');

    await store.putCiphertext(
      'media-user-a',
      mediaId,
      Uint8List.fromList([1, 2, 3]),
    );
    await store.putCiphertext(
      'media-user-b',
      mediaId,
      Uint8List.fromList([4, 5]),
    );

    expect(
      await store.getCiphertext('media-user-a', mediaId),
      Uint8List.fromList([1, 2, 3]),
    );
    expect(
      await store.getCiphertext('media-user-b', mediaId),
      Uint8List.fromList([4, 5]),
    );

    await store.clearUser('media-user-a');
    expect(await store.getCiphertext('media-user-a', mediaId), isNull);
    expect(await store.getCiphertext('media-user-b', mediaId), isNotNull);
  });
}
