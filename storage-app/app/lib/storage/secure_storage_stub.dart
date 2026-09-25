// Pure Dart / headless: no OS keystore (needs Flutter).
library;

Future<void> ensureSecureStorageReady() async {}

Future<String?> readSecureValue(String key) async => null;

Future<void> writeSecureValue(String key, String value) async {
  throw UnsupportedError(
    'OS keystore unavailable in headless Dart — set PPC_INSECURE_KEYS=1',
  );
}
