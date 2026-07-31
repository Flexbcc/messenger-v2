import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../../crypto/auth_keypair.dart';

/// Builds signed `X-PPC-*` request headers per storage-app/docs/WIRE.md.
class PpcSigner {
  PpcSigner({
    required this.authKeyPair,
    required this.nodeId,
  });

  final AuthKeyPair authKeyPair;
  final String nodeId;

  static final _sha256 = Sha256();

  /// Wire-format public key: `ed25519:<base64>`.
  String get publicKeyWire => 'ed25519:${authKeyPair.publicKeyBase64}';

  /// request-target for canonical string (path + query when present).
  static String canonicalPath(Uri uri) =>
      uri.query.isEmpty ? uri.path : '${uri.path}?${uri.query}';

  /// Canonical bytes: `<METHOD>\n<PATH>\n<timestamp>\n<hex(sha256(body))>`.
  static Future<List<int>> canonicalString({
    required String method,
    required String path,
    required int timestamp,
    required List<int> body,
  }) async {
    final bodyHash = await _sha256Hex(body);
    return utf8.encode('$method\n$path\n$timestamp\n$bodyHash');
  }

  /// Build authentication headers for a signed PPC request.
  Future<Map<String, String>> signHeaders({
    required String method,
    required String path,
    List<int> body = const [],
    int? timestampSeconds,
  }) async {
    final ts = timestampSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final message = await canonicalString(
      method: method.toUpperCase(),
      path: path,
      timestamp: ts,
      body: body,
    );
    final signature = await authKeyPair.signBase64(message);
    return {
      'X-PPC-Node-Id': nodeId,
      'X-PPC-Pubkey': publicKeyWire,
      'X-PPC-Timestamp': '$ts',
      'X-PPC-Signature': signature,
    };
  }

  static Future<String> _sha256Hex(List<int> body) async {
    final digest = await _sha256.hash(body);
    return digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
