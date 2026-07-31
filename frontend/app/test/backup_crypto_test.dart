import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/services/backup_crypto.dart';

void main() {
  test('backup encryption round trips and uses a fresh salt', () async {
    final first = await BackupCrypto.encryptJson({'key': 'secret'}, 'long-test-password');
    final second = await BackupCrypto.encryptJson({'key': 'secret'}, 'long-test-password');

    expect(first['salt'], isNot(second['salt']));
    expect(await BackupCrypto.decryptJson(first, 'long-test-password'), {'key': 'secret'});
  });
}
