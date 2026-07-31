import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config.dart';

/// Realtime channel with automatic reconnect (spec/0202_DELIVERY.md).
class RealtimeService {
  WebSocketChannel? _channel;
  StreamSubscription? _socketSub;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  Timer? _reconnectTimer;

  String? _token;
  Future<String> Function()? _tokenProvider;
  int _attempt = 0;
  bool _intentionalDisconnect = false;

  /// Fired every time a socket is (re-)opened, including the initial
  /// connect — best-effort/optimistic like the rest of this class (we don't
  /// wait for a server ack). Multi-device v0 (0405): the app controller uses
  /// this to trigger an `after=` catch-up so a network-blip reconnect (not
  /// just app resume) doesn't leave a gap in history.
  void Function()? onConnected;

  Stream<Map<String, dynamic>> get messages => _controller.stream;

  bool get isConnected => _channel != null;

  bool send(Map<String, dynamic> event) {
    final channel = _channel;
    if (channel == null) return false;
    try {
      channel.sink.add(jsonEncode(event));
      return true;
    } catch (_) {
      return false;
    }
  }

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

    final uri = Uri.parse('${AppConfig.wsUrl}?token=$token');
    try {
      _channel = WebSocketChannel.connect(uri);
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
      onConnected?.call();
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
