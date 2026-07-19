// storage-app :: transport/signature
// Проверка подписи запроса по WIRE.md §Аутентификация.
//
// Canonical string:
//   <METHOD>\n<PATH>\n<X-PPC-Timestamp>\n<hex(sha256(body))>
// PATH — request-target (path + '?' + query, если query есть). Нода подписывает
// ровно это. Окно времени ±300с. Подпись Ed25519, pubkey должен быть в paired.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

class SignatureHeaders {
  final String nodeId;
  final String pubkey; // "ed25519:<base64>"
  final int timestamp;
  final String signatureB64;

  SignatureHeaders({
    required this.nodeId,
    required this.pubkey,
    required this.timestamp,
    required this.signatureB64,
  });
}

enum AuthResult { ok, missingHeaders, badTimestamp, badSignature, notPaired }

class SignatureVerifier {
  static final Ed25519 _algo = Ed25519();
  final int windowSeconds;

  SignatureVerifier({this.windowSeconds = 300});

  /// request-target для canonical-строки.
  static String canonicalPath(Uri uri) =>
      uri.query.isEmpty ? uri.path : '${uri.path}?${uri.query}';

  /// Собрать canonical-строку по WIRE.md.
  static List<int> canonicalString({
    required String method,
    required String path,
    required int timestamp,
    required List<int> body,
  }) {
    final bodyHash = sha256.convert(body).toString();
    return utf8.encode('$method\n$path\n$timestamp\n$bodyHash');
  }

  /// Проверить: заголовки есть, окно времени, подпись, pubkey в paired.
  Future<AuthResult> verify({
    required SignatureHeaders? headers,
    required String method,
    required Uri uri,
    required Uint8List body,
    required bool Function(String pubkey) isPaired,
    int? nowSeconds,
  }) async {
    if (headers == null) return AuthResult.missingHeaders;
    final now = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if ((now - headers.timestamp).abs() > windowSeconds) {
      return AuthResult.badTimestamp;
    }
    final pubBytes = _decodePubkey(headers.pubkey);
    if (pubBytes == null) return AuthResult.badSignature;

    final Uint8List sig;
    try {
      sig = base64.decode(headers.signatureB64);
    } catch (_) {
      return AuthResult.badSignature;
    }
    final message = canonicalString(
      method: method,
      path: canonicalPath(uri),
      timestamp: headers.timestamp,
      body: body,
    );
    final publicKey =
        SimplePublicKey(pubBytes, type: KeyPairType.ed25519);
    final valid = await _algo.verify(
      message,
      signature: Signature(sig, publicKey: publicKey),
    );
    if (!valid) return AuthResult.badSignature;
    if (!isPaired(headers.pubkey)) return AuthResult.notPaired;
    return AuthResult.ok;
  }

  static Uint8List? _decodePubkey(String pubkey) {
    const prefix = 'ed25519:';
    if (!pubkey.startsWith(prefix)) return null;
    try {
      final b = base64.decode(pubkey.substring(prefix.length));
      if (b.length != 32) return null;
      return b;
    } catch (_) {
      return null;
    }
  }
}
