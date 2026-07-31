import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/services/persistent_media_store.dart';

void main() {
  test('ciphertext is scoped by account and can be cleared', () async {
    final store = PersistentMediaStore.instance;
    await store.clearUser('media-user-a');
    await store.clearUser('media-user-b');

    await store.putCiphertext(
      'media-user-a',
      'same-id',
      Uint8List.fromList([1, 2, 3]),
    );
    await store.putCiphertext(
      'media-user-b',
      'same-id',
      Uint8List.fromList([4, 5]),
    );

    expect(
      await store.getCiphertext('media-user-a', 'same-id'),
      Uint8List.fromList([1, 2, 3]),
    );
    expect(
      await store.getCiphertext('media-user-b', 'same-id'),
      Uint8List.fromList([4, 5]),
    );

    await store.clearUser('media-user-a');
    expect(await store.getCiphertext('media-user-a', 'same-id'), isNull);
    expect(await store.getCiphertext('media-user-b', 'same-id'), isNotNull);
  });
}
