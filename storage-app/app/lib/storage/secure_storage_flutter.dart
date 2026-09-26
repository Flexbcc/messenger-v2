// Flutter / desktop: flutter_secure_storage backend.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _storage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
  mOptions: MacOsOptions(
    // Data Protection Keychain requires a signed keychain-access-groups
    // entitlement. Local unsigned builds use the classic Keychain; production
    // signing can enable it without ever moving secrets to ordinary files.
    useDataProtectionKeyChain: false,
  ),
);

bool _bindingReady = false;
final Map<String, String?> _sessionCache = {};

Future<void> ensureSecureStorageReady() async {
  if (_bindingReady) return;
  WidgetsFlutterBinding.ensureInitialized();
  _bindingReady = true;
}

Future<String?> readSecureValue(String key) async {
  if (_sessionCache.containsKey(key)) return _sessionCache[key];
  final value = await _storage.read(key: key);
  _sessionCache[key] = value;
  return value;
}

Future<void> writeSecureValue(String key, String value) async {
  await _storage.write(key: key, value: value);
  _sessionCache[key] = value;
}
