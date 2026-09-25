import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

const _maxDirectResponseBytes = 64 * 1024 * 1024;
const _maxRelayEnvelopeBytes = 96 * 1024 * 1024;

Future<PpcTransportResponse> _sendBounded(
  http.Client client,
  http.Request request, {
  required Duration timeout,
  required int maxBytes,
}) async {
  request
    ..followRedirects = false
    ..maxRedirects = 0;
  final streamed = await client.send(request).timeout(timeout);
  final declared = streamed.contentLength;
  if (declared != null && (declared < 0 || declared > maxBytes)) {
    throw http.ClientException('PPC response is too large');
  }
  final body = BytesBuilder(copy: false);
  var received = 0;
  await for (final chunk in streamed.stream.timeout(timeout)) {
    received += chunk.length;
    if (received > maxBytes) {
      throw http.ClientException('PPC response is too large');
    }
    body.add(chunk);
  }
  return PpcTransportResponse(
    statusCode: streamed.statusCode,
    body: body.takeBytes(),
    headers: streamed.headers,
  );
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
      hdrs.addAll(
        await signer.signHeaders(
          method: method,
          path: PpcSigner.canonicalPath(uri),
          body: body,
        ),
      );
    }

    final upper = method.toUpperCase();
    if (!const {'GET', 'POST', 'PUT', 'DELETE'}.contains(upper)) {
      throw ArgumentError('unsupported method: $method');
    }
    final request = http.Request(upper, uri)
      ..headers.addAll(hdrs)
      ..bodyBytes = body;
    return _sendBounded(
      _client,
      request,
      timeout: requestTimeout,
      maxBytes: _maxDirectResponseBytes,
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
      hdrs.addAll(
        await signer.signHeaders(method: method, path: path, body: body),
      );
    }

    final invokeBody = jsonEncode({
      'method': method.toUpperCase(),
      'path': path,
      'headers': hdrs,
      'body_b64': body.isEmpty ? '' : base64Encode(body),
    });

    final relayBase = Uri.parse(relayUrl);
    if ((relayBase.scheme != 'http' && relayBase.scheme != 'https') ||
        relayBase.host.isEmpty ||
        relayBase.userInfo.isNotEmpty ||
        (relayBase.path.isNotEmpty && relayBase.path != '/') ||
        relayBase.hasQuery ||
        relayBase.hasFragment ||
        storageNodeId.isEmpty ||
        storageNodeId.length > 256 ||
        !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(storageNodeId)) {
      throw const FormatException('invalid relay endpoint');
    }
    final invokeUri = relayBase.replace(
      path: '/relay/ppc/${Uri.encodeComponent(storageNodeId)}/invoke',
    );
    final request = http.Request('POST', invokeUri)
      ..headers['Content-Type'] = 'application/json'
      ..body = invokeBody;
    final resp = await _sendBounded(
      _client,
      request,
      timeout: requestTimeout,
      maxBytes: _maxRelayEnvelopeBytes,
    );

    if (resp.statusCode >= 400) {
      return PpcTransportResponse(statusCode: resp.statusCode, body: resp.body);
    }

    final decoded = jsonDecode(utf8.decode(resp.body));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('invalid relay response');
    }
    final statusRaw = decoded['status'];
    final status = statusRaw is int ? statusRaw : resp.statusCode;
    if (status < 100 || status > 599) {
      throw const FormatException('invalid relay response status');
    }
    final encodedBody = decoded['body_b64'];
    if (encodedBody is! String) {
      throw const FormatException('invalid relay response body');
    }
    final respBody = base64Decode(encodedBody);
    if (respBody.length > _maxDirectResponseBytes) {
      throw const FormatException('relay response body is too large');
    }
    final respHeaders = <String, String>{};
    final headersRaw = decoded['headers'];
    if (headersRaw is Map && headersRaw.length <= 100) {
      headersRaw.forEach((key, value) {
        if (key is String &&
            value is String &&
            key.isNotEmpty &&
            key.length <= 128 &&
            value.length <= 8192) {
          respHeaders[key] = value;
        }
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
      ...List.generate(
        _transports.length - _activeIdx!,
        (i) => _activeIdx! + i,
      ),
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
  if (hint.isEmpty || hint.length > 2048) {
    throw ArgumentError('lan hint empty');
  }
  if (!hint.contains('://')) {
    hint = 'http://$hint';
  }
  final uri = Uri.parse(hint);
  final host = uri.host;
  if (host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw ArgumentError('invalid lan hint: $lanHint');
  }
  final port = uri.hasPort ? uri.port : PpcReach.defaultPort;
  if (port < 1 || port > 65535 || !_isLocalHost(host)) {
    throw ArgumentError('LAN endpoint must use a local address');
  }
  return Uri(scheme: uri.scheme, host: host, port: port);
}

bool _isLocalHost(String host) {
  final normalized = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (normalized == 'localhost' || normalized.endsWith('.local')) return true;
  final address = InternetAddress.tryParse(normalized);
  if (address == null) return false;
  if (address.isLoopback || address.isLinkLocal) return true;
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168);
  }
  // fc00::/7 — IPv6 unique-local addresses.
  return address.type == InternetAddressType.IPv6 && (bytes[0] & 0xfe) == 0xfc;
}
