import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config.dart';
import 'debug_log.dart';

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
  bool _connected = false;
  static const _maxIncomingChars = 2 * 1024 * 1024;
  static const _maxOutgoingChars = 4096;

  /// Fired every time a socket is (re-)opened, including the initial
  /// connect — best-effort/optimistic like the rest of this class (we don't
  /// wait for a server ack). Multi-device v0 (0405): the app controller uses
  /// this to trigger an `after=` catch-up so a network-blip reconnect (not
  /// just app resume) doesn't leave a gap in history.
  void Function()? onConnected;

  Stream<Map<String, dynamic>> get messages => _controller.stream;

  bool get isConnected => _connected;

  bool send(Map<String, dynamic> event) {
    final channel = _channel;
    if (channel == null || !_connected) return false;
    try {
      final encoded = jsonEncode(event);
      if (encoded.length > _maxOutgoingChars) return false;
      channel.sink.add(encoded);
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
    _connected = false;

    final token = _token;
    if (token == null) return;

    final uri = Uri.parse(
      AppConfig.wsUrl,
    ).replace(queryParameters: {'token': token});
    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      _socketSub = channel.stream.listen(
        (raw) {
          if (raw is! String || raw.length > _maxIncomingChars) {
            channel.sink.close(1009, 'invalid message');
            return;
          }
          try {
            final decoded = jsonDecode(raw);
            if (decoded is Map<String, dynamic>) {
              _controller.add(decoded);
            } else {
              channel.sink.close(1003, 'invalid message');
            }
          } on FormatException {
            channel.sink.close(1003, 'invalid json');
          }
        },
        onError: (_) => _scheduleReconnect(channel),
        onDone: () => _scheduleReconnect(channel),
        cancelOnError: false,
      );
      unawaited(
        channel.ready
            .then((_) {
              if (_channel != channel || _intentionalDisconnect) return;
              _connected = true;
              _attempt = 0;
              onConnected?.call();
            })
            .catchError((Object error) {
              _scheduleReconnect(channel);
            }),
      );
    } catch (_) {
      // WebSocket exceptions may embed the connection URI, whose query
      // contains the access token. Never print the exception verbatim.
      DebugLog.instance.warn('realtime', 'WebSocket connection failed');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect([WebSocketChannel? source]) {
    if (source != null && _channel != source) return;
    if (_intentionalDisconnect || _token == null) return;
    _connected = false;
    _channel = null;
    _socketSub = null;
    _reconnectTimer?.cancel();
    final seconds = min(30, pow(2, _attempt).toInt());
    _attempt++;
    _reconnectTimer = Timer(Duration(seconds: seconds), () async {
      if (_intentionalDisconnect || _token == null) return;
      if (_tokenProvider != null) {
        try {
          _token = await _tokenProvider!();
        } catch (error) {
          DebugLog.instance.warn(
            'realtime',
            'access token refresh failed',
            error,
          );
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
    _connected = false;
    _token = null;
    _tokenProvider = null;
    _attempt = 0;
  }
}
