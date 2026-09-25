import 'api_client.dart';
import 'debug_log.dart';

class CallIceService {
  const CallIceService(this._api);

  final ApiClient _api;

  Future<List<Map<String, dynamic>>> resolve({
    required bool allowRelays,
    required List<String> stunUrls,
  }) async {
    final servers = <Map<String, dynamic>>[
      if (stunUrls.isNotEmpty) {'urls': stunUrls},
    ];
    if (!allowRelays) {
      DebugLog.instance.info(
        'calls',
        stunUrls.isEmpty
            ? 'relay and external STUN disabled — local ICE only'
            : 'node.allow_relays=false — configured STUN only',
      );
      return servers;
    }

    try {
      final nodes = await _api.findNodes(capability: 'turn');
      final online = nodes.where((node) => node['status'] == 'online');
      if (online.isEmpty) return servers;

      final nodeUrl = online.first['node_url'];
      if (nodeUrl is! String || nodeUrl.isEmpty) return servers;
      final credentials = await _api.fetchTurnCredentials(nodeUrl);
      final rawUris = credentials['uris'];
      final uris = rawUris is List
          ? rawUris
                .take(16)
                .whereType<String>()
                .where(_isUsableTurnUri)
                .toList()
          : <String>[];
      final username = credentials['username'];
      final password = credentials['password'];
      if (uris.isNotEmpty &&
          username is String &&
          username.isNotEmpty &&
          username.length <= 512 &&
          password is String &&
          password.isNotEmpty &&
          password.length <= 1024) {
        servers.add({
          'urls': uris,
          'username': username,
          'credential': password,
        });
      } else {
        DebugLog.instance.warn(
          'calls',
          'TURN credentials or public URIs are unavailable',
        );
      }
    } catch (error) {
      DebugLog.instance.warn('calls', 'TURN discovery failed: $error');
    }
    return servers;
  }

  bool _isUsableTurnUri(String uri) {
    if (uri.isEmpty || uri.length > 512 || uri.codeUnits.any((c) => c < 33)) {
      return false;
    }
    final lower = uri.toLowerCase();
    if (!lower.startsWith('turn:') && !lower.startsWith('turns:')) return false;
    return !lower.contains('localhost') && !lower.contains('127.0.0.1');
  }
}
