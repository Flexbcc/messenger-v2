// mDNS browse for storage-app PPC services (_ouo-ppc._tcp).
//
// Mirrors shared/storage/personal_pc_pairing.py discover_ppc_lan_hints().

import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import 'ppc_payload.dart';

const _defaultPpcServiceType = '_ouo-ppc._tcp';

/// Browse LAN for storage-app PPC services; returns `host:port` hints.
///
/// Prefers resolved IP/hostname from SRV lookup. Returns an empty list on web
/// and other platforms where mDNS is unavailable (never throws).
Future<List<String>> discoverPpcLanHints({
  Duration timeout = const Duration(seconds: 3),
  String serviceType = _defaultPpcServiceType,
}) async {
  if (kIsWeb) return const [];

  BonsoirDiscovery? discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? subscription;
  final hints = <String>[];
  final seen = <String>{};

  try {
    discovery = BonsoirDiscovery(type: serviceType);
    await discovery.ready;

    subscription = discovery.eventStream!.listen((event) {
      switch (event.type) {
        case BonsoirDiscoveryEventType.discoveryServiceFound:
          final service = event.service;
          if (service != null) {
            service.resolve(discovery!.serviceResolver);
          }
        case BonsoirDiscoveryEventType.discoveryServiceResolved:
          _collectHint(event.service, hints, seen);
        default:
          break;
      }
    });

    await discovery.start();
    await Future<void>.delayed(timeout);
  } catch (_) {
    // mDNS unavailable on this platform — return empty list.
  } finally {
    await subscription?.cancel();
    try {
      await discovery?.stop();
    } catch (_) {}
  }

  return hints;
}

void _collectHint(
  BonsoirService? service,
  List<String> hints,
  Set<String> seen,
) {
  if (service is! ResolvedBonsoirService) return;
  final port = service.port > 0 ? service.port : PpcReach.defaultPort;

  final hostRaw = service.host?.trim();
  if (hostRaw == null || hostRaw.isEmpty) return;
  final host = hostRaw.replaceAll(RegExp(r'\.$'), '');
  final hint = '$host:$port';
  if (seen.add(hint)) hints.add(hint);
}
