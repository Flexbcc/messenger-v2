// mDNS-объявление storage-app в LAN (SPEC §7, service _ouo-ppc._tcp).
// Требует Flutter (bonsoir → dart:ui).
library;

import 'package:bonsoir/bonsoir.dart';

/// Публикует storage-app в локальной сети для автообнаружения нодой.
class PpcMdnsAdvertiser {
  BonsoirBroadcast? _broadcast;

  Future<void> start({
    required int port,
    required String fingerprint,
    required String storagePubkey,
  }) async {
    await stop();
    final service = BonsoirService(
      name: 'storage-app',
      type: '_ouo-ppc._tcp',
      port: port,
      attributes: {
        'fp': fingerprint,
        // Короткий префикс ключа — полный в QR/JSON.
        'pk': storagePubkey.length > 48
            ? storagePubkey.substring(0, 48)
            : storagePubkey,
      },
    );
    _broadcast = BonsoirBroadcast(service: service);
    // bonsoir 5.x: ready → start (initialize() removed).
    await _broadcast!.ready;
    await _broadcast!.start();
  }

  Future<void> stop() async {
    if (_broadcast != null) {
      await _broadcast!.stop();
      _broadcast = null;
    }
  }
}
