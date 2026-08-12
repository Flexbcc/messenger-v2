import 'dart:convert';

/// Relay hints embedded in pairing payload `reach.relay`.
class PpcRelayReach {
  const PpcRelayReach({
    required this.discoveryUrl,
    required this.storageNodeId,
    required this.relayUrl,
  });

  final String discoveryUrl;
  final String storageNodeId;
  final String relayUrl;

  factory PpcRelayReach.fromJson(Map<String, dynamic> json) {
    return PpcRelayReach(
      discoveryUrl: (json['discovery_url'] as String? ?? '').trim(),
      storageNodeId: (json['storage_node_id'] as String? ?? '').trim(),
      relayUrl: (json['relay_url'] as String? ?? '').trim(),
    );
  }

  Map<String, Object?> toJson() => {
    'discovery_url': discoveryUrl,
    'storage_node_id': storageNodeId,
    'relay_url': relayUrl,
  };

  bool get isComplete => relayUrl.isNotEmpty && storageNodeId.isNotEmpty;
}

/// Route resolution hints from QR payload v2 (or synthesized from v1).
class PpcReach {
  const PpcReach({
    required this.lan,
    required this.port,
    this.mdns = '_ouo-ppc._tcp',
    this.relay,
  });

  static const defaultPort = 7345;

  final List<String> lan;
  final int port;
  final String? mdns;
  final PpcRelayReach? relay;

  factory PpcReach.fromJson(Map<String, dynamic> json) {
    PpcRelayReach? relay;
    final relayRaw = json['relay'];
    if (relayRaw is Map<String, dynamic>) {
      relay = PpcRelayReach.fromJson(relayRaw);
      if (!relay.isComplete) relay = null;
    }
    final lanRaw = json['lan'];
    final lan = <String>[];
    if (lanRaw is List) {
      for (final entry in lanRaw) {
        final host = entry.toString().trim();
        if (host.isNotEmpty) lan.add(host);
      }
    }
    return PpcReach(
      lan: lan,
      port: (json['port'] as num?)?.toInt() ?? defaultPort,
      mdns: json['mdns'] as String? ?? '_ouo-ppc._tcp',
      relay: relay,
    );
  }

  /// Build `host:port` hints for LAN-direct transport.
  List<String> get lanHints =>
      lan.map((host) => '$host:$port').where((h) => h.isNotEmpty).toList();
}

/// Parsed `ouo_ppc_pair` JSON from QR or clipboard.
class PpcPairingPayload {
  PpcPairingPayload({
    required this.version,
    required this.code,
    required this.storagePubkey,
    required this.expiresAt,
    required this.intent,
    required this.reach,
    this.fingerprint,
  });

  static const kind = 'ouo_ppc_pair';

  final int version;
  final String code;
  final String storagePubkey;
  final int expiresAt;
  final String intent;
  final PpcReach reach;
  final String? fingerprint;

  /// Parse raw JSON string (QR / paste buffer).
  static PpcPairingPayload parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw PpcPayloadError('empty payload');
    }
    try {
      final data = jsonDecode(trimmed) as Map<String, dynamic>;
      return fromMap(data);
    } on FormatException catch (e) {
      throw PpcPayloadError('invalid JSON: $e');
    }
  }

  static PpcPairingPayload fromMap(Map<String, dynamic> data) {
    if (data['kind'] != kind) {
      throw PpcPayloadError('unexpected kind: ${data['kind']}');
    }

    final code = (data['code'] as String? ?? '').trim();
    if (code.length != 6 || int.tryParse(code) == null) {
      throw PpcPayloadError('code must be 6 digits');
    }

    final storagePubkey = (data['storage_pubkey'] as String? ?? '').trim();
    if (!storagePubkey.startsWith('ed25519:')) {
      throw PpcPayloadError('storage_pubkey missing or invalid');
    }

    final expiresAt = (data['expires_at'] as num?)?.toInt() ?? 0;
    if (expiresAt > 0 &&
        expiresAt < DateTime.now().millisecondsSinceEpoch ~/ 1000) {
      throw PpcPayloadError('pairing code expired');
    }

    final version = (data['v'] as num?)?.toInt() ?? 1;
    final reach = _reachFromPayload(data, version);
    final intent =
        (data['intent'] as String? ?? (version == 1 ? 'node' : 'node')).trim();

    return PpcPairingPayload(
      version: version,
      code: code,
      storagePubkey: storagePubkey,
      expiresAt: expiresAt,
      intent: intent.isEmpty ? 'node' : intent,
      reach: reach,
      fingerprint: data['fingerprint'] as String?,
    );
  }

  static PpcReach _reachFromPayload(Map<String, dynamic> data, int version) {
    final reachRaw = data['reach'];
    if (reachRaw is Map<String, dynamic>) {
      return PpcReach.fromJson(reachRaw);
    }
    // Legacy v1: flat lan/port without reach object.
    return PpcReach.fromJson({
      'lan': data['lan'] ?? const [],
      'port': data['port'] ?? PpcReach.defaultPort,
      'mdns': data['mdns'] ?? true,
    });
  }
}

class PpcPayloadError implements Exception {
  PpcPayloadError(this.message);
  final String message;
  @override
  String toString() => 'PpcPayloadError: $message';
}

enum PpcRouteKind { lan, relay }

/// Outcome of a successful `/ppc/pair` with resolved route metadata.
class PpcPairResult {
  const PpcPairResult({
    required this.storagePubkey,
    required this.routeKind,
    this.lanHint,
    this.relayUrl,
    this.storageNodeId,
    this.fingerprint,
  });

  final String storagePubkey;
  final PpcRouteKind routeKind;
  final String? lanHint;
  final String? relayUrl;
  final String? storageNodeId;
  final String? fingerprint;
}
