// storage-app :: storage/secure_key_store
// Секреты в OS-keystore (SETTINGS.md §3). Ed25519 seed + AES-ключ meta.db.
//
// Headless/CI/tests: `PPC_INSECURE_KEYS=1` или `FLUTTER_TEST` → файловый fallback
// (keys.json / plaintext meta.db), без Keychain.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'secure_storage_stub.dart'
    if (dart.library.ui) 'secure_storage_flutter.dart' as secure;

/// OS-keystore для ключей storage-app.
class SecureKeyStore {
  SecureKeyStore._();

  static const metaDbKeyName = 'ppc.meta_db_key';
  static const storageSeedKeyName = 'ppc.storage_seed';

  static final _ed25519 = Ed25519();
  static final _random = Random.secure();

  /// `true` → seed в keys.json, meta.db без шифрования (только dev/test).
  static bool get insecureMode {
    final env = Platform.environment;
    return env['PPC_INSECURE_KEYS'] == '1' || env.containsKey('FLUTTER_TEST');
  }

  /// Нужен для flutter_secure_storage в Flutter UI / `flutter run`.
  static Future<void> ensureInitialized() async {
    if (insecureMode) return;
    await secure.ensureSecureStorageReady();
  }

  /// 32-байтовый AES-ключ для meta.db. `null` в [insecureMode] (plaintext БД).
  static Future<List<int>?> loadOrCreateMetaDbKey() async {
    if (insecureMode) return null;
    await ensureInitialized();
    final existing = await secure.readSecureValue(metaDbKeyName);
    if (existing != null) return base64Decode(existing);
    final bytes = _randomBytes(32);
    await secure.writeSecureValue(metaDbKeyName, base64Encode(bytes));
    return bytes;
  }

  /// Ed25519 seed storage-app. В insecure-режиме — keys.json в [allowedRoot].
  static Future<List<int>> loadOrCreateStorageSeed(String allowedRoot) async {
    if (insecureMode) {
      return _loadOrCreateSeedFile(allowedRoot);
    }
    await ensureInitialized();

    final stored = await secure.readSecureValue(storageSeedKeyName);
    if (stored != null) return base64Decode(stored);

    final legacy = File(p.join(allowedRoot, 'keys.json'));
    if (await legacy.exists()) {
      final data =
          jsonDecode(await legacy.readAsString()) as Map<String, Object?>;
      final seed = base64.decode(data['seed'] as String);
      await secure.writeSecureValue(storageSeedKeyName, base64Encode(seed));
      try {
        await legacy.delete();
      } catch (_) {}
      return seed;
    }

    final kp = await _ed25519.newKeyPair();
    final seed = await kp.extractPrivateKeyBytes();
    await secure.writeSecureValue(storageSeedKeyName, base64Encode(seed));
    return seed;
  }

  static List<int> _randomBytes(int n) =>
      List<int>.generate(n, (_) => _random.nextInt(256));

  static Future<List<int>> _loadOrCreateSeedFile(String allowedRoot) async {
    final file = File(p.join(allowedRoot, 'keys.json'));
    if (await file.exists()) {
      final data =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      return base64.decode(data['seed'] as String);
    }
    final kp = await _ed25519.newKeyPair();
    final seed = await kp.extractPrivateKeyBytes();
    final pub = await kp.extractPublicKey();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({
      'seed': base64.encode(seed),
      'public': base64.encode(pub.bytes),
    }));
    try {
      await Process.run('chmod', ['600', file.path]);
    } catch (_) {}
    return seed;
  }
}
