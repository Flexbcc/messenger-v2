// Flutter / desktop: flutter_secure_storage backend.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _storage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
  mOptions: MacOsOptions(useDataProtectionKeyChain: false),
);

bool _bindingReady = false;

Future<void> ensureSecureStorageReady() async {
  if (_bindingReady) return;
  WidgetsFlutterBinding.ensureInitialized();
  _bindingReady = true;
}

Future<String?> readSecureValue(String key) async {
  try {
    return await _storage.read(key: key);
  } catch (_) {
    return null;
  }
}

Future<void> writeSecureValue(String key, String value) async {
  await _storage.write(key: key, value: value);
}
