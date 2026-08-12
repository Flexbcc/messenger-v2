import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:messenger_app/screens/private_mode/private_mode_state.dart';
import 'package:messenger_app/security/private_feature_access.dart';
import 'package:messenger_app/services/privacy_preferences_store.dart';

void main() {
  test(
    'PIN persists across a fresh state instance and is never stored as plaintext',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});

      final first = PrivateModeState();
      await first.load();
      await first.configurePins(realPin: '123456', fakePin: '000000');

      final prefs = await SharedPreferences.getInstance();
      final allValues = prefs
          .getKeys()
          .map((k) => prefs.get(k).toString())
          .join(' ');
      expect(allValues.contains('123456'), isFalse);
      expect(allValues.contains('000000'), isFalse);

      final second = PrivateModeState();
      await second.load();
      expect(second.isConfigured, isTrue);
      expect(await second.evaluate('123456'), UnlockResult.realPin);
      expect(await second.evaluate('000000'), UnlockResult.fakePin);
      expect(await second.evaluate('999999'), UnlockResult.invalid);
    },
  );

  test('secret features require both primary and additional PIN', () async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});

    var access = await PrivateFeatureAccess.load();
    expect(access.canConfigureDecoyPin, isFalse);
    expect(access.canUseSecretFeatures, isFalse);

    final state = PrivateModeState(wipeVault: () async {});
    await state.configurePins(realPin: '123456');
    access = await PrivateFeatureAccess.load();
    expect(access.canConfigureDecoyPin, isTrue);
    expect(access.canUseSecretFeatures, isFalse);

    await state.configurePins(realPin: '123456', fakePin: '000000');
    access = await PrivateFeatureAccess.load();
    expect(access.canUseSecretFeatures, isTrue);
  });

  test('reset removes PIN access and every dependent feature flag', () async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = PrivacyPreferencesStore();
    final state = PrivateModeState(wipeVault: () async {});

    await state.configurePins(realPin: '123456', fakePin: '000000');
    await prefs.setFakePinEnabled(true);
    await prefs.setDecoyPinStepComplete(true);
    await prefs.setSecretRoomEnabled(true);
    await prefs.setHiddenChatsEnabled(true);
    await prefs.setAppLockEnabled(true);
    await prefs.setWipeOnWrongAttempts(true);

    await state.reset();

    final access = await PrivateFeatureAccess.load();
    expect(access.hasPrimaryPin, isFalse);
    expect(access.hasDecoyPin, isFalse);
    expect(access.canUseSecretFeatures, isFalse);
    expect(await state.evaluate('123456'), UnlockResult.invalid);
    expect(await state.evaluate('000000'), UnlockResult.invalid);
    expect(await prefs.fakePinEnabled(), isFalse);
    expect(await prefs.decoyPinStepComplete(), isFalse);
    expect(await prefs.secretRoomEnabled(), isFalse);
    expect(await prefs.hiddenChatsEnabled(), isFalse);
    expect(await prefs.appLockEnabled(), isFalse);
    expect(await prefs.wipeOnWrongAttempts(), isFalse);
  });
}
