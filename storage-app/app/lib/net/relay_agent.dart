// Исходящий WebSocket-агент storage-app → relay (SPEC §7 relay-fallback).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../pairing/keys.dart';

/// Держит исходящий канал к relay и проксирует invoke → localhost PPC server.
class PpcRelayAgent {
  static const _reconnectDelay = Duration(seconds: 5);
  static const _maxInvokeBodyBytes = 64 * 1024 * 1024;
  static const _maxResponseBodyBytes = 64 * 1024 * 1024;
  static const _maxHeaders = 64;
  static final RegExp _nodeIdPattern = RegExp(r'^[A-Za-z0-9._:-]+$');
  static final Random _random = Random.secure();

  final String relayUrl;
  final String storageNodeId;
  final String storagePubkey;
  final int localPort;
  final StorageKeys? keys;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  bool _running = false;
  bool _connecting = false;

  PpcRelayAgent({
    required this.relayUrl,
    required this.storageNodeId,
    required this.storagePubkey,
    required this.localPort,
    this.keys,
  });

  Future<void> start() async {
    if (_running) return;
    _validateConfiguration();
    _running = true;
    await _connect();
  }

  Future<void> stop() async {
    _running = false;
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
  }

  Future<void> _connect() async {
    if (!_running || _connecting) return;
    _connecting = true;
    try {
      await _sub?.cancel();
      _sub = null;
      await _channel?.sink.close();
      _channel = null;

      final uri = _wsUri(
        '${relayUrl.replaceAll(RegExp(r'/+$'), '')}/relay/ppc/agent',
      );
      final channel = IOWebSocketChannel.connect(
        uri,
        headers: await _federationHeaders(),
        connectTimeout: const Duration(seconds: 15),
      );
      await channel.ready;
      channel.sink.add(jsonEncode(await _buildHandshake()));
      _channel = channel;
      _sub = channel.stream.listen(
        _onMessage,
        onError: (Object e) {
          stderr.writeln('relay agent ws error: $e');
          _scheduleReconnect();
        },
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
    } catch (e) {
      stderr.writeln('relay agent connect failed: $e');
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  /// Строим handshake-сообщение. Если ключи доступны — добавляем подпись,
  /// чтобы relay мог проверить что мы владеем приватным ключом.
  /// Canonical payload: `RELAY_HANDSHAKE\nnode_id\ntimestamp`.
  Future<Map<String, Object>> _buildHandshake() async {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final payload = <String, Object>{
      'node_id': storageNodeId,
      'storage_pubkey': storagePubkey,
      'timestamp': ts,
    };
    final canonical = utf8.encode('RELAY_HANDSHAKE\n$storageNodeId\n$ts');
    final bodyHash = sha256.convert(canonical).toString();
    final sigBytes = await keys!.sign(
      utf8.encode('RELAY_HANDSHAKE\n$storageNodeId\n$ts\n$bodyHash'),
    );
    payload['signature'] = base64.encode(sigBytes);
    return payload;
  }

  Future<Map<String, String>> _federationHeaders() async {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final nonce = _uuidV4();
    const path = '/relay/ppc/agent';
    final digest = sha256.convert(const <int>[]).toString();
    final canonical = utf8.encode(
      '$storageNodeId|$timestamp|$nonce|GET|$path|$digest',
    );
    final signature = base64Encode(await keys!.sign(canonical));
    return {
      'X-Federation-Node-Id': storageNodeId,
      'X-Federation-Timestamp': timestamp,
      'X-Federation-Nonce': nonce,
      'X-Federation-Signature': signature,
    };
  }

  void _scheduleReconnect() {
    if (!_running) return;
    _sub?.cancel();
    _sub = null;
    _channel = null;
    Future<void>.delayed(_reconnectDelay, _connect);
  }

  Future<void> _onMessage(dynamic raw) async {
    Map<String, dynamic> msg;
    try {
      if (raw is! String || utf8.encode(raw).length > 96 * 1024 * 1024) {
        throw const FormatException('invalid relay message');
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('invalid relay message');
      }
      msg = decoded;
    } catch (e) {
      stderr.writeln('relay agent bad message: $e');
      return;
    }
    final type = msg['type'] as String?;
    if (type != null && type != 'invoke') return;
    if (!msg.containsKey('method') || !msg.containsKey('path')) return;
    await _handleInvoke(msg);
  }

  Future<void> _handleInvoke(Map<String, dynamic> msg) async {
    final id = msg['id'];
    final methodRaw = msg['method'];
    final pathRaw = msg['path'];
    if (id is! String ||
        id.length > 128 ||
        methodRaw is! String ||
        pathRaw is! String) {
      _sendInvalidInvoke(id);
      return;
    }
    final method = methodRaw.toUpperCase();
    final path = _validateInvokePath(method, pathRaw);
    final headers = _stringMap(msg['headers']);
    final body = _decodeBody(msg['body_b64']);
    if (path == null || headers == null || body == null) {
      _sendInvalidInvoke(id);
      return;
    }

    final client = HttpClient();
    HttpClientResponse? resp;
    try {
      final uri = Uri.parse('http://127.0.0.1:$localPort$path');
      final req = await _openRequest(client, method, uri);
      headers.forEach(req.headers.set);
      if (body.isNotEmpty) {
        req.add(body);
      }
      resp = await req.close();
      final respBody = <int>[];
      await for (final chunk in resp) {
        if (respBody.length + chunk.length > _maxResponseBodyBytes) {
          throw const HttpException('local PPC response is too large');
        }
        respBody.addAll(chunk);
      }
      final respHeaders = <String, String>{};
      resp.headers.forEach((name, values) {
        if (values.isNotEmpty) respHeaders[name] = values.first;
      });
      _send({
        'type': 'response',
        'id': id,
        'status': resp.statusCode,
        'headers': respHeaders,
        'body_b64': base64.encode(respBody),
      });
    } catch (e) {
      stderr.writeln('relay invoke $method $path failed: $e');
      _send({
        'type': 'response',
        'id': id,
        'status': 502,
        'headers': {'content-type': 'application/json'},
        'body_b64': base64.encode(
          utf8.encode(jsonEncode({'error': 'agent_forward_failed'})),
        ),
      });
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpClientRequest> _openRequest(
    HttpClient client,
    String method,
    Uri uri,
  ) {
    switch (method) {
      case 'GET':
        return client.getUrl(uri);
      case 'POST':
        return client.postUrl(uri);
      case 'PUT':
        return client.putUrl(uri);
      case 'DELETE':
        return client.deleteUrl(uri);
      case 'HEAD':
        return client.headUrl(uri);
      case 'PATCH':
        return client.openUrl('PATCH', uri);
      default:
        return client.openUrl(method, uri);
    }
  }

  void _send(Map<String, Object?> body) {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(jsonEncode(body));
    } catch (e) {
      stderr.writeln('relay agent send failed: $e');
    }
  }

  static Uri _wsUri(String httpUrl) {
    final parsed = Uri.parse(httpUrl);
    final scheme = switch (parsed.scheme) {
      'https' => 'wss',
      'http' => 'ws',
      'wss' || 'ws' => parsed.scheme,
      _ => throw const FormatException('invalid relay URL scheme'),
    };
    return parsed.replace(scheme: scheme);
  }

  static Map<String, String>? _stringMap(Object? raw) {
    if (raw is! Map || raw.length > _maxHeaders) return null;
    final result = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String ||
          value is! String ||
          key.isEmpty ||
          key.length > 128 ||
          value.length > 8192 ||
          key.runes.any((rune) => rune < 0x21 || rune > 0x7e) ||
          value.runes.any((rune) => rune < 0x20 && rune != 0x09)) {
        return null;
      }
      final normalized = key.toLowerCase();
      if (!const {
        'content-type',
        'range',
        'x-ppc-node-id',
        'x-ppc-pubkey',
        'x-ppc-timestamp',
        'x-ppc-signature',
      }.contains(normalized)) {
        return null;
      }
      result[key] = value;
    }
    return result;
  }

  static List<int>? _decodeBody(Object? bodyB64) {
    if (bodyB64 == null || bodyB64 == '') return const [];
    if (bodyB64 is! String ||
        bodyB64.length > ((_maxInvokeBodyBytes + 2) ~/ 3) * 4) {
      return null;
    }
    try {
      final decoded = base64.decode(bodyB64);
      if (decoded.length > _maxInvokeBodyBytes ||
          base64.encode(decoded) != bodyB64) {
        return null;
      }
      return decoded;
    } catch (_) {
      return null;
    }
  }

  static String? _validateInvokePath(String method, String raw) {
    if (!const {'GET', 'POST', 'PUT', 'DELETE'}.contains(method) ||
        raw.isEmpty ||
        raw.length > 2048 ||
        !raw.startsWith('/ppc/') ||
        raw.startsWith('//') ||
        raw.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
      return null;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.hasScheme || uri.hasAuthority || uri.hasFragment) {
      return null;
    }
    return raw;
  }

  void _sendInvalidInvoke(Object? id) {
    _send({
      'type': 'response',
      if (id is String && id.length <= 128) 'id': id,
      'status': 400,
      'headers': {'content-type': 'application/json'},
      'body_b64': base64Encode(
        utf8.encode(jsonEncode({'error': 'invalid_invoke'})),
      ),
    });
  }

  void _validateConfiguration() {
    if (keys == null ||
        storageNodeId.isEmpty ||
        storageNodeId.length > 256 ||
        !_nodeIdPattern.hasMatch(storageNodeId) ||
        storagePubkey != keys!.publicKeyString ||
        localPort < 1 ||
        localPort > 65535) {
      throw StateError('invalid PPC relay agent configuration');
    }
    final uri = Uri.tryParse(relayUrl);
    if (uri == null ||
        !const {'https', 'wss'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw StateError('PPC relay URL must be an HTTPS/WSS origin');
    }
  }

  static String _uuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
