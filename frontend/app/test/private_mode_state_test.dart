import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:messenger_app/screens/private_mode/private_mode_state.dart';
import 'package:messenger_app/security/private_feature_access.dart';
import 'package:messenger_app/security/pin_security.dart';
import 'package:messenger_app/services/local_settings_store.dart';
import 'package:messenger_app/services/app_privacy_session.dart';
import 'package:messenger_app/services/app_lock_service.dart';
import 'package:messenger_app/services/privacy_preferences_store.dart';
import 'package:messenger_app/security/secret_chat_security.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    LocalSettingsStore.setActiveUser('private-mode-test-user');
    PinSecurity.setActiveUser('private-mode-test-user');
  });

  test(
    'PIN persists across a fresh state instance and is never stored as plaintext',
    () async {
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

  test(
    'fake PIN enters decoy context and cannot unlock secret features',
    () async {
      final state = PrivateModeState(wipeVault: () async {});
      await state.configurePins(realPin: '123456', fakePin: '000000');

      expect(await state.evaluate('000000'), UnlockResult.fakePin);
      AppPrivacySession.instance.enterDecoyMode();
      expect(AppPrivacySession.instance.isInDecoyMode, isTrue);
      expect(
        await AppPrivacySession.instance.canAccessSecretFeatures(),
        isFalse,
      );

      expect(await state.evaluate('123456'), UnlockResult.realPin);
      AppPrivacySession.instance.enterPrivateMode();
      expect(AppPrivacySession.instance.isInDecoyMode, isFalse);
      expect(
        await AppPrivacySession.instance.canAccessSecretFeatures(),
        isTrue,
      );
    },
  );

  test(
    'primary and fake PIN can never be configured to the same value',
    () async {
      final state = PrivateModeState(wipeVault: () async {});
      await state.configurePins(realPin: '123456');
      await expectLater(
        state.configurePins(realPin: '123456', fakePin: '123456'),
        throwsFormatException,
      );

      await PinSecurity.saveFakePin('000000');
      await expectLater(
        PinSecurity.saveRealPin('000000'),
        throwsFormatException,
      );
    },
  );

  test('reset removes PIN access and every dependent feature flag', () async {
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

  test(
    'cold start locks an enabled app and decoy exit can force lock',
    () async {
      await PinSecurity.saveRealPin('123456');
      final prefs = PrivacyPreferencesStore();
      await prefs.setAppLockEnabled(true);

      await AppLockService.instance.init();
      expect(AppLockService.instance.isLocked, isTrue);

      AppLockService.instance.unlock();
      await prefs.setAppLockEnabled(false);
      await AppLockService.instance.refreshEnabled();
      await AppLockService.instance.lockNow(force: true);
      expect(AppLockService.instance.isLocked, isTrue);
    },
  );

  test(
    'secret-room password separates mandatory errors from warnings',
    () async {
      expect(
        SecretChatSecurity.blockingErrorsForSetup('777777'),
        contains('Минимум 8 символов'),
      );
      expect(
        SecretChatSecurity.warningsForSetup('12345678'),
        contains('Слишком простой пароль'),
      );

      await SecretChatSecurity.savePassword('Correct-Horse-42');
      expect(await SecretChatSecurity.isConfigured(), isTrue);
      expect(await SecretChatSecurity.verify('Correct-Horse-42'), isTrue);
      expect(await SecretChatSecurity.verify('wrong-password'), isFalse);
    },
  );
}
