import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:messenger_app/screens/private_mode/private_mode_state.dart';

void main() {
  test('PIN persists across a fresh state instance and is never stored as plaintext', () async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});

    final first = PrivateModeState();
    await first.load();
    await first.configurePins(realPin: '123456', fakePin: '000000');

    final prefs = await SharedPreferences.getInstance();
    final allValues = prefs.getKeys().map((k) => prefs.get(k).toString()).join(' ');
    expect(allValues.contains('123456'), isFalse);
    expect(allValues.contains('000000'), isFalse);

    final second = PrivateModeState();
    await second.load();
    expect(second.isConfigured, isTrue);
    expect(await second.evaluate('123456'), UnlockResult.realPin);
    expect(await second.evaluate('000000'), UnlockResult.fakePin);
    expect(await second.evaluate('999999'), UnlockResult.invalid);
  });
}
