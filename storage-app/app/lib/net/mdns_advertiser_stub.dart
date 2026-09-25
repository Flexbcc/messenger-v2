// Headless / pure Dart: mDNS advertise unavailable (bonsoir needs Flutter).
library;

/// Explicitly unavailable when Flutter/`dart:ui` is not present.
class PpcMdnsAdvertiser {
  Future<void> start({
    required int port,
    required String fingerprint,
    required String storagePubkey,
  }) => throw UnsupportedError(
    'mDNS advertising requires the Flutter storage-app runtime',
  );

  Future<void> stop() async {}
}
