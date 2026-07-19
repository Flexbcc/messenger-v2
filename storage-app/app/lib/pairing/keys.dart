// storage-app :: pairing/keys
// Ключевая пара Ed25519 самого storage-app (PAIRING.md «Ключи»).
// Seed в OS-keystore (SETTINGS.md §3); keys.json — только миграция / insecure-режим.
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../storage/secure_key_store.dart';

/// Ключи storage-app: генерация при первом старте, загрузка при последующих.
class StorageKeys {
  final SimpleKeyPair keyPair;
  final List<int> publicKeyBytes;

  StorageKeys(this.keyPair, this.publicKeyBytes);

  static final Ed25519 _algo = Ed25519();

  /// "ed25519:<base64(pub)>" — формат из WIRE.md.
  String get publicKeyString => 'ed25519:${base64.encode(publicKeyBytes)}';

  /// Отпечаток для сверки (PAIRING.md, MITM-защита) — первые байты pub в hex.
  String get fingerprint {
    final b = publicKeyBytes;
    return List.generate(8, (i) => b[i].toRadixString(16).padLeft(2, '0'))
        .join(':');
  }

  /// Подписать canonical-строку (WIRE.md аутентификация).
  Future<List<int>> sign(List<int> message) async {
    final sig = await _algo.sign(message, keyPair: keyPair);
    return sig.bytes;
  }

  /// Загрузить seed из keystore (или keys.json при миграции / insecure-режиме).
  static Future<StorageKeys> loadOrCreate(String allowedRoot) async {
    final seed = await SecureKeyStore.loadOrCreateStorageSeed(allowedRoot);
    final kp = await _algo.newKeyPairFromSeed(seed);
    final pub = await kp.extractPublicKey();
    return StorageKeys(kp, pub.bytes);
  }
}
