// storage-app :: storage/secure_key_store
// Секреты в OS-keystore (SETTINGS.md §3). Ed25519 seed + AES-ключ meta.db.
//
// Tests may use a file-backed seed/plaintext DB. A manual insecure mode needs
// an explicit second acknowledgement and must never activate by accident.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'secure_storage_stub.dart'
    if (dart.library.ui) 'secure_storage_flutter.dart'
    as secure;

/// OS-keystore для ключей storage-app.
class SecureKeyStore {
  SecureKeyStore._();

  static const metaDbKeyName = 'ppc.meta_db_key';
  static const storageSeedKeyName = 'ppc.storage_seed';
  static const _insecureAcknowledgement = 'I_ACCEPT_PLAINTEXT_SECRETS';

  static final _ed25519 = Ed25519();
  static final _random = Random.secure();

  /// `true` → seed в keys.json, meta.db без шифрования (только dev/test).
  static bool get insecureMode {
    final env = Platform.environment;
    final testMode = env['FLUTTER_TEST'] == 'true';
    final explicitlyAcknowledged =
        env['PPC_INSECURE_KEYS'] == '1' &&
        env['PPC_ALLOW_INSECURE_KEY_STORAGE'] == _insecureAcknowledgement;
    if (env['PPC_INSECURE_KEYS'] == '1' && !explicitlyAcknowledged) {
      throw StateError(
        'insecure key storage requires an explicit plaintext acknowledgement',
      );
    }
    return testMode || explicitlyAcknowledged;
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
    if (existing != null) return _decodeKey(existing, metaDbKeyName);
    final bytes = _randomBytes(32);
    await secure.writeSecureValue(metaDbKeyName, base64Encode(bytes));
    final persisted = await secure.readSecureValue(metaDbKeyName);
    if (persisted == null ||
        !_constantTimeEquals(_decodeKey(persisted, metaDbKeyName), bytes)) {
      throw StateError('failed to persist meta database key');
    }
    return bytes;
  }

  /// Ed25519 seed storage-app. В insecure-режиме — keys.json в [allowedRoot].
  static Future<List<int>> loadOrCreateStorageSeed(String allowedRoot) async {
    if (insecureMode) {
      return _loadOrCreateSeedFile(allowedRoot);
    }
    await ensureInitialized();

    final stored = await secure.readSecureValue(storageSeedKeyName);
    final legacy = File(p.join(allowedRoot, 'keys.json'));
    if (stored != null) {
      final seed = _decodeKey(stored, storageSeedKeyName);
      await _removeLegacySeedFile(legacy, expectedSeed: seed);
      return seed;
    }

    if (await legacy.exists()) {
      final seed = await _readSeedFile(legacy);
      await secure.writeSecureValue(storageSeedKeyName, base64Encode(seed));
      final persisted = await secure.readSecureValue(storageSeedKeyName);
      if (persisted == null ||
          !_constantTimeEquals(
            _decodeKey(persisted, storageSeedKeyName),
            seed,
          )) {
        throw StateError('failed to migrate storage identity into keystore');
      }
      await legacy.delete();
      return seed;
    }

    final kp = await _ed25519.newKeyPair();
    final seed = await kp.extractPrivateKeyBytes();
    await secure.writeSecureValue(storageSeedKeyName, base64Encode(seed));
    final persisted = await secure.readSecureValue(storageSeedKeyName);
    if (persisted == null ||
        !_constantTimeEquals(_decodeKey(persisted, storageSeedKeyName), seed)) {
      throw StateError('failed to persist storage identity');
    }
    return seed;
  }

  static List<int> _randomBytes(int n) =>
      List<int>.generate(n, (_) => _random.nextInt(256));

  static Future<List<int>> _loadOrCreateSeedFile(String allowedRoot) async {
    final file = File(p.join(allowedRoot, 'keys.json'));
    if (await file.exists()) {
      return _readSeedFile(file);
    }
    final kp = await _ed25519.newKeyPair();
    final seed = await kp.extractPrivateKeyBytes();
    final pub = await kp.extractPublicKey();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'seed': base64.encode(seed),
        'public': base64.encode(pub.bytes),
      }),
    );
    try {
      await Process.run('chmod', ['600', file.path]);
    } catch (_) {}
    return seed;
  }

  static List<int> _decodeKey(String encoded, String label) {
    try {
      final decoded = base64Decode(encoded);
      if (decoded.length != 32 || base64Encode(decoded) != encoded) {
        throw const FormatException();
      }
      return decoded;
    } on FormatException {
      throw StateError('$label is corrupt');
    }
  }

  static Future<List<int>> _readSeedFile(File file) async {
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size > 4096) {
      throw StateError('legacy storage identity file is invalid');
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException();
      }
      return _decodeKey(decoded['seed'] as String, 'legacy storage seed');
    } catch (error) {
      if (error is StateError) rethrow;
      throw StateError('legacy storage identity file is corrupt');
    }
  }

  static Future<void> _removeLegacySeedFile(
    File file, {
    required List<int> expectedSeed,
  }) async {
    if (!await file.exists()) return;
    final legacySeed = await _readSeedFile(file);
    if (!_constantTimeEquals(legacySeed, expectedSeed)) {
      throw StateError('conflicting storage identities found');
    }
    await file.delete();
  }

  static bool _constantTimeEquals(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var i = 0; i < left.length; i++) {
      difference |= left[i] ^ right[i];
    }
    return difference == 0;
  }
}
