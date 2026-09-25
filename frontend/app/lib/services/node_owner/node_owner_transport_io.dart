import 'dart:io';

import 'package:crypto/crypto.dart';

import 'node_owner_http_transport.dart';

NodeOwnerTransport createNodeOwnerTransport() => IoNodeOwnerTransport();

class IoNodeOwnerTransport implements NodeOwnerTransport {
  static const _maxResponseBytes = 1024 * 1024;

  @override
  Future<NodeOwnerHttpResponse> send({
    required Uri uri,
    required String method,
    required Map<String, String> headers,
    required List<int> body,
    required String expectedCaFingerprint,
  }) async {
    final loopback =
        uri.scheme == 'http' &&
        (uri.host == '127.0.0.1' ||
            uri.host == 'localhost' ||
            uri.host == '::1');
    if (uri.scheme != 'https' && !loopback) {
      throw StateError('Удалённое управление требует HTTPS');
    }
    final expected = normalizeSha256Fingerprint(expectedCaFingerprint);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    if (uri.scheme == 'https' && expected.isNotEmpty) {
      client.badCertificateCallback = (certificate, host, port) =>
          sha256Fingerprint(certificate.der) == expected;
    }
    try {
      final request = await client.openUrl(method, uri);
      request.followRedirects = false;
      request.maxRedirects = 0;
      headers.forEach(request.headers.set);
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close();
      if (response.isRedirect) {
        throw StateError('Management API redirects are forbidden');
      }
      if (uri.scheme == 'https' && expected.isNotEmpty) {
        final certificate = response.certificate;
        if (certificate == null ||
            sha256Fingerprint(certificate.der) != expected) {
          throw StateError('Management TLS certificate fingerprint mismatch');
        }
      }
      if (response.contentLength > _maxResponseBytes) {
        throw StateError('Management API response is too large');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > _maxResponseBytes) {
          throw StateError('Management API response is too large');
        }
      }
      return NodeOwnerHttpResponse(
        statusCode: response.statusCode,
        body: bytes,
      );
    } finally {
      client.close(force: true);
    }
  }
}

String sha256Fingerprint(List<int> derBytes) =>
    sha256.convert(derBytes).toString();

String normalizeSha256Fingerprint(String value) {
  final normalized = value.trim().toLowerCase().replaceFirst('sha256:', '');
  if (normalized.isEmpty) return '';
  final compact = normalized.replaceAll(':', '');
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(compact)) {
    throw const FormatException('Некорректный SHA-256 fingerprint сертификата');
  }
  return compact;
}
