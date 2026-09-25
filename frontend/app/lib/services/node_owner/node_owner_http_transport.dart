import 'dart:convert';

import 'package:http/http.dart' as http;

class NodeOwnerHttpResponse {
  const NodeOwnerHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final List<int> body;

  Map<String, dynamic> jsonObject() {
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Management API returned a non-object');
    }
    return decoded;
  }
}

abstract interface class NodeOwnerTransport {
  Future<NodeOwnerHttpResponse> send({
    required Uri uri,
    required String method,
    required Map<String, String> headers,
    required List<int> body,
    required String expectedCaFingerprint,
  });
}

class StandardNodeOwnerTransport implements NodeOwnerTransport {
  StandardNodeOwnerTransport({http.Client? client})
    : _client = client ?? http.Client();

  static const _maxResponseBytes = 1024 * 1024;
  final http.Client _client;

  @override
  Future<NodeOwnerHttpResponse> send({
    required Uri uri,
    required String method,
    required Map<String, String> headers,
    required List<int> body,
    required String expectedCaFingerprint,
  }) async {
    if (uri.scheme != 'https' && !_isLoopback(uri)) {
      throw StateError('Удалённое управление требует HTTPS');
    }
    if (expectedCaFingerprint.isNotEmpty) {
      throw UnsupportedError(
        'Certificate pinning requires the native management transport',
      );
    }
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers.addAll(headers)
      ..bodyBytes = body;
    final streamed = await _client.send(request);
    if (streamed.isRedirect) {
      throw StateError('Management API redirects are forbidden');
    }
    final declared = streamed.contentLength;
    if (declared != null && declared > _maxResponseBytes) {
      throw StateError('Management API response is too large');
    }
    final bytes = await streamed.stream.toBytes();
    if (bytes.length > _maxResponseBytes) {
      throw StateError('Management API response is too large');
    }
    return NodeOwnerHttpResponse(statusCode: streamed.statusCode, body: bytes);
  }

  static bool _isLoopback(Uri uri) =>
      uri.scheme == 'http' &&
      (uri.host == '127.0.0.1' || uri.host == 'localhost' || uri.host == '::1');
}
