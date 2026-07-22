import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config.dart';

/// Receive-only push channel with automatic reconnect (spec/0202_DELIVERY.md).
class RealtimeService {
  WebSocketChannel? _channel;
  StreamSubscription? _socketSub;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  Timer? _reconnectTimer;

  String? _token;
  Future<String> Function()? _tokenProvider;
  int _attempt = 0;
  bool _intentionalDisconnect = false;

  Stream<Map<String, dynamic>> get messages => _controller.stream;

  bool get isConnected => _channel != null;

  void connect(String accessToken, {Future<String> Function()? tokenProvider}) {
    _intentionalDisconnect = false;
    _token = accessToken;
    _tokenProvider = tokenProvider;
    _attempt = 0;
    _open();
  }

  void _open() {
    _reconnectTimer?.cancel();
    _socketSub?.cancel();
    _channel?.sink.close();
    _channel = null;

    final token = _token;
    if (token == null) return;

    // Token is sent as the first WebSocket message (not in the URL) to avoid
    // it appearing in server logs, proxies, or browser history.
    final uri = Uri.parse(AppConfig.wsUrl);
    try {
      _channel = WebSocketChannel.connect(uri);
      _channel!.sink.add(jsonEncode({'type': 'auth', 'token': token}));
      _socketSub = _channel!.stream.listen(
        (raw) {
          _attempt = 0;
          final decoded = jsonDecode(raw as String) as Map<String, dynamic>;
          _controller.add(decoded);
        },
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('RealtimeService connect failed: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_intentionalDisconnect || _token == null) return;
    _reconnectTimer?.cancel();
    final seconds = min(30, pow(2, _attempt).toInt());
    _attempt++;
    _reconnectTimer = Timer(Duration(seconds: seconds), () async {
      if (_intentionalDisconnect || _token == null) return;
      if (_tokenProvider != null) {
        try {
          _token = await _tokenProvider!();
        } catch (e) {
          debugPrint('RealtimeService token refresh failed: $e');
        }
      }
      _open();
    });
  }

  /// Send a control message to the server over the open WebSocket.
  /// Safe to call when disconnected — message is silently dropped.
  void send(Map<String, dynamic> payload) {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(jsonEncode(payload));
    } catch (e) {
      debugPrint('RealtimeService.send failed: $e');
    }
  }

  void disconnect() {
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _socketSub?.cancel();
    _channel?.sink.close();
    _channel = null;
    _token = null;
    _tokenProvider = null;
    _attempt = 0;
  }
}
