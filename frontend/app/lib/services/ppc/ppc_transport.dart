import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'ppc_payload.dart';
import 'ppc_signing.dart';

/// Raw HTTP response from a PPC transport.
class PpcTransportResponse {
  const PpcTransportResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });

  final int statusCode;
  final List<int> body;
  final Map<String, String> headers;
}

/// Signed or unsigned PPC HTTP transport (LAN-direct or relay invoke).
abstract class PpcTransport {
  Future<PpcTransportResponse> request({
    required String method,
    required String path,
    Map<String, String>? headers,
    List<int> body = const [],
    bool signed = true,
  });
}

/// Direct LAN HTTP to storage-app base URL.
class LanPpcTransport implements PpcTransport {
  LanPpcTransport({
    required this.baseUri,
    required this.signer,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  final Uri baseUri;
  final PpcSigner signer;
  final http.Client _client;
  final Duration requestTimeout;

  @override
  Future<PpcTransportResponse> request({
    required String method,
    required String path,
    Map<String, String>? headers,
    List<int> body = const [],
    bool signed = true,
  }) async {
    final uri = baseUri.replace(path: path);
    final hdrs = Map<String, String>.from(headers ?? {});
    if (signed) {
      hdrs.addAll(await signer.signHeaders(
        method: method,
        path: PpcSigner.canonicalPath(uri),
        body: body,
      ));
    }

    final upper = method.toUpperCase();
    late http.Response resp;
    switch (upper) {
      case 'GET':
        resp = await _client.get(uri, headers: hdrs).timeout(requestTimeout);
      case 'POST':
        resp = await _client.post(uri, headers: hdrs, body: body).timeout(requestTimeout);
      case 'PUT':
        resp = await _client.put(uri, headers: hdrs, body: body).timeout(requestTimeout);
      case 'DELETE':
        resp = await _client.delete(uri, headers: hdrs).timeout(requestTimeout);
      default:
        throw ArgumentError('unsupported method: $method');
    }

    return PpcTransportResponse(
      statusCode: resp.statusCode,
      body: resp.bodyBytes,
      headers: resp.headers,
    );
  }
}

/// Relay invoke tunnel — legacy mode without federation auth headers.
class RelayPpcTransport implements PpcTransport {
  RelayPpcTransport({
    required this.relayUrl,
    required this.storageNodeId,
    required this.signer,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  final String relayUrl;
  final String storageNodeId;
  final PpcSigner signer;
  final http.Client _client;
  final Duration requestTimeout;

  @override
  Future<PpcTransportResponse> request({
    required String method,
    required String path,
    Map<String, String>? headers,
    List<int> body = const [],
    bool signed = true,
  }) async {
    final hdrs = Map<String, String>.from(headers ?? {});
    if (signed) {
      hdrs.addAll(await signer.signHeaders(
        method: method,
        path: path,
        body: body,
      ));
    }

    final invokeBody = jsonEncode({
      'method': method.toUpperCase(),
      'path': path,
      'headers': hdrs,
      'body_b64': body.isEmpty ? '' : base64Encode(body),
    });

    final base = relayUrl.replaceAll(RegExp(r'/+$'), '');
    final invokeUri = Uri.parse('$base/relay/ppc/$storageNodeId/invoke');
    final resp = await _client
        .post(
          invokeUri,
          headers: {'Content-Type': 'application/json'},
          body: invokeBody,
        )
        .timeout(requestTimeout);

    if (resp.statusCode >= 400) {
      return PpcTransportResponse(
        statusCode: resp.statusCode,
        body: resp.bodyBytes,
      );
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final status = (data['status'] as num?)?.toInt() ?? resp.statusCode;
    final respBody = base64Decode(data['body_b64'] as String? ?? '');
    final respHeaders = <String, String>{};
    final headersRaw = data['headers'];
    if (headersRaw is Map) {
      headersRaw.forEach((key, value) {
        respHeaders['$key'] = '$value';
      });
    }

    return PpcTransportResponse(
      statusCode: status,
      body: respBody,
      headers: respHeaders,
    );
  }
}

/// Ordered failover: LAN-direct → relay. Sticks to last working route.
class CompositePpcTransport implements PpcTransport {
  CompositePpcTransport({required List<PpcTransport> transports})
      : _transports = List.unmodifiable(transports) {
    if (_transports.isEmpty) {
      throw ArgumentError('transports must not be empty');
    }
  }

  final List<PpcTransport> _transports;
  int? _activeIdx;

  static bool _isRetryableNetworkError(Object error) {
    return error is SocketException ||
        error is TimeoutException ||
        error is http.ClientException;
  }

  static bool _isRetryableStatus(int statusCode) => statusCode >= 502;

  List<int> get _tryOrder {
    if (_activeIdx == null) {
      return List.generate(_transports.length, (i) => i);
    }
    return [
      ...List.generate(_transports.length - _activeIdx!, (i) => _activeIdx! + i),
      ...List.generate(_activeIdx!, (i) => i),
    ];
  }

  @override
  Future<PpcTransportResponse> request({
    required String method,
    required String path,
    Map<String, String>? headers,
    List<int> body = const [],
    bool signed = true,
  }) async {
    PpcTransportResponse? lastResponse;
    Object? lastError;

    for (final idx in _tryOrder) {
      try {
        final resp = await _transports[idx].request(
          method: method,
          path: path,
          headers: headers,
          body: body,
          signed: signed,
        );
        if (_isRetryableStatus(resp.statusCode)) {
          lastResponse = resp;
          continue;
        }
        _activeIdx = idx;
        return resp;
      } catch (e) {
        if (_isRetryableNetworkError(e)) {
          lastError = e;
          continue;
        }
        rethrow;
      }
    }

    if (lastResponse != null) return lastResponse;
    if (lastError != null) throw lastError;
    throw StateError('all PPC transports failed');
  }
}

/// Parse `host:port` or URL into a LAN base URI (default port 7345).
Uri parseLanBase(String lanHint) {
  var hint = lanHint.trim();
  if (hint.isEmpty) {
    throw ArgumentError('lan hint empty');
  }
  if (!hint.contains('://')) {
    hint = 'http://$hint';
  }
  final uri = Uri.parse(hint);
  final host = uri.host;
  if (host.isEmpty) {
    throw ArgumentError('invalid lan hint: $lanHint');
  }
  final port = uri.hasPort ? uri.port : PpcReach.defaultPort;
  final scheme = uri.scheme.isEmpty ? 'http' : uri.scheme;
  return Uri(scheme: scheme, host: host, port: port);
}
