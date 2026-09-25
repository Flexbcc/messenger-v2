import 'dart:convert';

final RegExp _ppcNodeIdPattern = RegExp(r'^[A-Za-z0-9._:-]+$');
final RegExp _ppcFingerprintPattern = RegExp(
  r'^[0-9a-f]{2}(?::[0-9a-f]{2}){7}$',
);

String validatePpcStoragePubkey(Object? value) {
  if (value is! String || !value.startsWith('ed25519:')) {
    throw PpcPayloadError('storage_pubkey missing or invalid');
  }
  final encoded = value.substring(8);
  try {
    final decoded = base64Decode(encoded);
    if (decoded.length != 32 || base64Encode(decoded) != encoded) {
      throw const FormatException();
    }
  } on FormatException {
    throw PpcPayloadError('storage_pubkey missing or invalid');
  }
  return value;
}

String ppcStorageFingerprint(String storagePubkey) {
  final validated = validatePpcStoragePubkey(storagePubkey);
  final bytes = base64Decode(validated.substring(8));
  return bytes
      .take(8)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join(':');
}

String validatePpcNodeId(Object? value, {String field = 'node id'}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 256 ||
      !_ppcNodeIdPattern.hasMatch(value)) {
    throw PpcPayloadError('invalid $field');
  }
  return value;
}

String validatePpcRelayUrl(Object? value) {
  if (value is! String || value.isEmpty || value.length > 2048) {
    throw PpcPayloadError('invalid relay endpoint');
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw PpcPayloadError('invalid relay endpoint');
  }
  return value;
}

String? validatePpcFingerprint(Object? value, String storagePubkey) {
  if (value == null) return null;
  if (value is! String || !_ppcFingerprintPattern.hasMatch(value)) {
    throw PpcPayloadError('invalid storage fingerprint');
  }
  if (value != ppcStorageFingerprint(storagePubkey)) {
    throw PpcPayloadError('storage fingerprint does not match public key');
  }
  return value;
}

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
    final discoveryUrl = (json['discovery_url'] as String? ?? '').trim();
    final storageNodeId = (json['storage_node_id'] as String? ?? '').trim();
    final relayUrl = (json['relay_url'] as String? ?? '').trim();
    if (storageNodeId.isNotEmpty) {
      validatePpcNodeId(storageNodeId, field: 'relay storage node id');
    }
    for (final entry in [discoveryUrl, relayUrl]) {
      if (entry.isEmpty) continue;
      validatePpcRelayUrl(entry);
    }
    return PpcRelayReach(
      discoveryUrl: discoveryUrl,
      storageNodeId: storageNodeId,
      relayUrl: relayUrl,
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
      if (lanRaw.length > 32) {
        throw PpcPayloadError('too many LAN addresses');
      }
      for (final entry in lanRaw) {
        final host = entry.toString().trim();
        if (host.length > 255) throw PpcPayloadError('invalid LAN address');
        if (host.isNotEmpty) lan.add(host);
      }
    }
    final portRaw = json['port'];
    final port = portRaw ?? defaultPort;
    if (port is! int || port < 1 || port > 65535) {
      throw PpcPayloadError('invalid LAN port');
    }
    final mdns = json['mdns'];
    if (mdns != null && mdns is! String && mdns is! bool) {
      throw PpcPayloadError('invalid mDNS setting');
    }
    return PpcReach(
      lan: lan,
      port: port,
      mdns: mdns is String ? mdns : (mdns == false ? null : '_ouo-ppc._tcp'),
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
    if (utf8.encode(trimmed).length > 64 * 1024) {
      throw PpcPayloadError('pairing payload is too large');
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, dynamic>) {
        throw PpcPayloadError('pairing payload must be an object');
      }
      final data = decoded;
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

    final storagePubkey = validatePpcStoragePubkey(data['storage_pubkey']);

    final expiresRaw = data['expires_at'];
    if (expiresRaw is! int) {
      throw PpcPayloadError('expires_at must be an integer');
    }
    final expiresAt = expiresRaw;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (expiresAt <= now || expiresAt > now + 86400) {
      throw PpcPayloadError('pairing code expired');
    }

    final versionRaw = data['v'];
    final version = versionRaw ?? 1;
    if (version is! int || version < 1 || version > 2) {
      throw PpcPayloadError('unsupported pairing payload version');
    }
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
      fingerprint: validatePpcFingerprint(data['fingerprint'], storagePubkey),
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
