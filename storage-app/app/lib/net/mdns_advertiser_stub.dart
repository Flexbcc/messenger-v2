// Headless / pure Dart: mDNS advertise unavailable (bonsoir needs Flutter).
library;

/// No-op advertiser when Flutter/`dart:ui` is not present.
class PpcMdnsAdvertiser {
  Future<void> start({
    required int port,
    required String fingerprint,
    required String storagePubkey,
  }) async {}

  Future<void> stop() async {}
}
