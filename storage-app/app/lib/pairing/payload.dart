// JSON-payload для QR pairing (PAIRING.md — код + pubkey + reach-хинты).
library;

import 'dart:convert';

/// Relay-хинты для pairing payload (direct-mode / NAT fallback).
class PpcRelayReach {
  final String discoveryUrl;
  final String storageNodeId;
  final String relayUrl;

  const PpcRelayReach({
    required this.discoveryUrl,
    required this.storageNodeId,
    required this.relayUrl,
  });

  Map<String, Object?> toJson() => {
        'discovery_url': discoveryUrl,
        'storage_node_id': storageNodeId,
        'relay_url': relayUrl,
      };
}

/// Сборка payload для QR / копирования в буфер.
class PairingPayload {
  static const kind = 'ouo_ppc_pair';
  static const version = 1;

  static String encode({
    required String code,
    required String storagePubkey,
    required String fingerprint,
    required int expiresAt,
    String intent = 'node',
    required List<String> lanHosts,
    required int port,
    bool mdns = true,
    PpcRelayReach? relay,
  }) {
    final reach = <String, Object?>{
      'lan': lanHosts,
      'port': port,
      'mdns': mdns,
    };
    if (relay != null) {
      reach['relay'] = relay.toJson();
    }
    return jsonEncode({
      'v': version,
      'kind': kind,
      'intent': intent,
      'code': code,
      'storage_pubkey': storagePubkey,
      'fingerprint': fingerprint,
      'expires_at': expiresAt,
      'reach': reach,
    });
  }
}
