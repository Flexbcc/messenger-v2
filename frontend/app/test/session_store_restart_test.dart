import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/services/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySecrets implements SessionSecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> remove(String key) async => values.remove(key);

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'current-format session survives a fresh SessionStore instance',
    () async {
      final secrets = _MemorySecrets();
      await SessionStore(secrets: secrets).save(
        userId: 'user-reload',
        deviceId: 'device-reload',
        accessToken: 'a' * 64,
        displayName: 'Reload QA',
      );

      final restored = await SessionStore(secrets: secrets).load();
      expect(restored, isNotNull);
      expect(restored!.userId, 'user-reload');
      expect(restored.deviceId, 'device-reload');
      expect(restored.accessToken, 'a' * 64);
      expect(restored.displayName, 'Reload QA');
    },
  );

  test(
    'missing secure token clears session but retains identity locator',
    () async {
      final secrets = _MemorySecrets();
      final first = SessionStore(secrets: secrets);
      await first.save(
        userId: 'user-legacy',
        deviceId: 'device-legacy',
        accessToken: 'b' * 64,
        displayName: 'Legacy QA',
      );
      secrets.values.clear();

      final restarted = SessionStore(secrets: secrets);
      expect(await restarted.load(), isNull);
      final locator = await restarted.loadRememberedIdentity();
      expect(locator, isNotNull);
      expect(locator!.userId, 'user-legacy');
      expect(locator.deviceId, 'device-legacy');
    },
  );
}
