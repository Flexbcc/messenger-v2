// Исходящий WebSocket-агент storage-app → relay (SPEC §7 relay-fallback).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../pairing/keys.dart';

/// Держит исходящий канал к relay и проксирует invoke → localhost PPC server.
class PpcRelayAgent {
  static const _reconnectDelay = Duration(seconds: 5);

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

      final uri = _wsUri('${relayUrl.replaceAll(RegExp(r'/+$'), '')}/relay/ppc/agent');
      final channel = WebSocketChannel.connect(uri);
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
  /// Canonical payload для подписи: "RELAY_HANDSHAKE\n<node_id>\n<timestamp>".
  Future<Map<String, Object>> _buildHandshake() async {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final payload = <String, Object>{
      'node_id': storageNodeId,
      'storage_pubkey': storagePubkey,
      'timestamp': ts,
    };
    final k = keys;
    if (k != null) {
      final canonical = utf8.encode('RELAY_HANDSHAKE\n$storageNodeId\n$ts');
      final bodyHash = sha256.convert(canonical).toString();
      final sigBytes = await k.sign(utf8.encode('RELAY_HANDSHAKE\n$storageNodeId\n$ts\n$bodyHash'));
      payload['signature'] = base64.encode(sigBytes);
    }
    return payload;
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
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
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
    final method = (msg['method'] as String).toUpperCase();
    final path = msg['path'] as String;
    final headers = _stringMap(msg['headers']);
    final body = _decodeBody(msg['body_b64'] as String?);

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
      final respBody = await resp.fold(<int>[], (prev, chunk) => prev..addAll(chunk));
      final respHeaders = <String, String>{};
      resp.headers.forEach((name, values) {
        if (values.isNotEmpty) respHeaders[name] = values.first;
      });
      _send({
        'type': 'response',
        if (id != null) 'id': id,
        'status': resp.statusCode,
        'headers': respHeaders,
        'body_b64': base64.encode(respBody),
      });
    } catch (e) {
      stderr.writeln('relay invoke $method $path failed: $e');
      _send({
        'type': 'response',
        if (id != null) 'id': id,
        'status': 502,
        'headers': {'content-type': 'application/json'},
        'body_b64': base64.encode(utf8.encode(
          jsonEncode({'error': 'agent_forward_failed', 'detail': '$e'}),
        )),
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
      _ => 'ws',
    };
    return parsed.replace(scheme: scheme);
  }

  static Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map) return {};
    return raw.map((k, v) => MapEntry('$k', '$v'));
  }

  static List<int> _decodeBody(String? bodyB64) {
    if (bodyB64 == null || bodyB64.isEmpty) return const [];
    try {
      return base64.decode(bodyB64);
    } catch (_) {
      return const [];
    }
  }
}
