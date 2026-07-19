import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/device_info.dart';
import 'network_usage_store.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Thin REST client for Home Node + Media Node. No retries/backoff here —
/// see spec/0202_DELIVERY.md for what a production transport layer owes;
/// this is intentionally the simple version (ADR-0004).
class ApiClient {
  ApiClient({this.accessToken});

  String? accessToken;
  final _networkUsage = NetworkUsageStore();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (accessToken != null) 'Authorization': 'Bearer $accessToken',
      };

  Uri _homeUri(String path) => Uri.parse('${AppConfig.homeNodeUrl}$path');
  Uri _mediaUri(String path) => Uri.parse('${AppConfig.mediaNodeUrl}$path');
  Uri _discoveryUri(String path) => Uri.parse('${AppConfig.discoveryNodeUrl}$path');

  Future<void> _trackReceived(http.Response resp) async {
    try {
      await _networkUsage.recordReceived(resp.bodyBytes.length);
    } catch (_) {
      // SharedPreferences unavailable outside a Flutter app context (tests).
    }
  }

  Future<void> _trackSent(int bytes) async {
    if (bytes <= 0) return;
    try {
      await _networkUsage.recordSent(bytes);
    } catch (_) {
      // SharedPreferences unavailable outside a Flutter app context (tests).
    }
  }

  NetworkUsageStore get networkUsage => _networkUsage;

  Future<http.Response> _postJson(Uri uri, Map<String, dynamic> body) async {
    final encoded = jsonEncode(body);
    await _trackSent(utf8.encode(encoded).length);
    return http.post(uri, headers: _headers, body: encoded);
  }

  Future<http.Response> _patchJson(Uri uri, Map<String, dynamic> body) async {
    final encoded = jsonEncode(body);
    await _trackSent(utf8.encode(encoded).length);
    return http.patch(uri, headers: _headers, body: encoded);
  }

  Future<http.Response> _get(Uri uri) async => http.get(uri, headers: _headers);

  Future<http.Response> _delete(Uri uri) async => http.delete(uri, headers: _headers);

  dynamic _decodeOrThrow(http.Response resp) {
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      unawaited(_trackReceived(resp));
      if (resp.body.isEmpty) return null;
      return jsonDecode(resp.body);
    }
    String message = resp.body;
    try {
      message = (jsonDecode(resp.body) as Map)['detail']?.toString() ?? resp.body;
    } catch (_) {}
    throw ApiException(resp.statusCode, message);
  }

  /// ADR-0007 temporary bridge: phone required, login/email optional, password.
  Future<Map<String, dynamic>> register({
    required String displayName,
    required String phone,
    String? login,
    String? email,
    required String password,
    required String deviceName,
    required String deviceType,
    required String authPublicKey,
    required Map<String, dynamic> identityKeyBundle,
  }) async {
    final resp = await _postJson(_homeUri('/auth/register'), {
        'display_name': displayName,
        'phone': phone,
        'login': login,
        'email': email,
        'password': password,
        'device_name': deviceName,
        'device_type': deviceType,
        'auth_public_key': authPublicKey,
        'identity_key_bundle': identityKeyBundle,
      });
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  /// ADR-0007 temporary bridge login by phone/login/email + password.
  Future<Map<String, dynamic>> loginWithPassword({
    required String identifier,
    required String password,
    required String deviceName,
    required String deviceType,
    required String authPublicKey,
    required Map<String, dynamic> identityKeyBundle,
  }) async {
    final resp = await _postJson(_homeUri('/auth/login'), {
        'identifier': identifier,
        'password': password,
        'device_name': deviceName,
        'device_type': deviceType,
        'auth_public_key': authPublicKey,
        'identity_key_bundle': identityKeyBundle,
      });
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> challenge(String deviceId) async {
    final resp = await _postJson(_homeUri('/auth/challenge'), {'device_id': deviceId});
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> verify({
    required String deviceId,
    required String nonce,
    required String signature,
  }) async {
    final resp = await _postJson(_homeUri('/auth/verify'), {
        'device_id': deviceId,
        'nonce': nonce,
        'signature': signature,
      });
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getMyProfile() async {
    final resp = await _get(_homeUri('/users/me'));
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getProfileSettings() async {
    final resp = await _get(_homeUri('/users/me/profile-settings'));
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  Future<void> updateProfileSettings(Map<String, dynamic> blob) async {
    final encoded = jsonEncode(blob);
    await _trackSent(encoded.length);
    final resp = await http.put(
      _homeUri('/users/me/profile-settings'),
      headers: _headers,
      body: encoded,
    );
    await _trackReceived(resp);
    _decodeOrThrow(resp);
  }

  Future<Map<String, dynamic>> updateDisplayName(String displayName) async {
    final resp = await _patchJson(_homeUri('/users/me'), {'display_name': displayName});
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getPreKeyBundle(String userId) async {
    final resp = await _get(_homeUri('/users/$userId/prekey-bundle'));
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  Future<List<dynamic>> listConversations() async {
    final resp = await _get(_homeUri('/conversations'));
    return _decodeOrThrow(resp) as List<dynamic>;
  }

  Future<Map<String, dynamic>> createConversation({
    required String type,
    String? name,
    required List<String> participantUserIds,
  }) async {
    final resp = await _postJson(_homeUri('/conversations'), {
        'type': type,
        'name': name,
        'participant_user_ids': participantUserIds,
      });
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> sendMessage({
    required String conversationId,
    required String ciphertext,
    required String contentType,
    String cryptoVersion = 'signal-v1',
    String? clientMsgId,
  }) async {
    final resp = await _postJson(_homeUri('/conversations/$conversationId/messages'), {
        'ciphertext': ciphertext,
        'content_type': contentType,
        'crypto_version': cryptoVersion,
        'client_msg_id': clientMsgId,
      });
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  Future<List<dynamic>> getMessages(String conversationId, {int limit = 50, String? before}) async {
    final query = {'limit': '$limit', if (before != null) 'before': before};
    final uri = _homeUri('/conversations/$conversationId/messages').replace(queryParameters: query);
    final resp = await _get(uri);
    return _decodeOrThrow(resp) as List<dynamic>;
  }

  Future<String> uploadMedia(Uint8List bytes, String filename) async {
    await _trackSent(bytes.length);
    final headers = <String, String>{};
    if (accessToken != null) headers['Authorization'] = 'Bearer $accessToken';
    final request = http.MultipartRequest('POST', _mediaUri('/media'))
      ..headers.addAll(headers)
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamed = await request.send();
    final resp = await http.Response.fromStream(streamed);
    final data = _decodeOrThrow(resp) as Map<String, dynamic>;
    return data['media_id'] as String;
  }

  /// Production path: JWT on Home Node → federation to Media Node.
  Future<Uint8List> downloadMedia(String mediaId) async {
    final headers = <String, String>{};
    if (accessToken != null) headers['Authorization'] = 'Bearer $accessToken';
    final resp = await http.get(_homeUri('/media/$mediaId'), headers: headers);
    if (resp.statusCode != 200) {
      throw ApiException(resp.statusCode, 'media download failed');
    }
    unawaited(_trackReceived(resp));
    return resp.bodyBytes;
  }

  /// Nodes advertising [capability] (e.g. `'turn'`, `'relay'`) via Discovery
  /// Node — see spec/0604_DISCOVERY_NODE.md. Includes offline entries; the
  /// caller filters on `status`.
  Future<List<dynamic>> findNodes({required String capability}) async {
    final resp = await _get(_discoveryUri('/registry/nodes').replace(queryParameters: {'capability': capability}));
    final decoded = _decodeOrThrow(resp) as Map<String, dynamic>;
    return decoded['nodes'] as List<dynamic>;
  }

  /// Time-limited TURN credentials from a specific Turn Node — see
  /// spec/0605_TURN_NODE.md. [turnNodeUrl] comes from [findNodes].
  Future<Map<String, dynamic>> fetchTurnCredentials(String turnNodeUrl) async {
    final resp = await http.post(Uri.parse('$turnNodeUrl/turn/credentials'));
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final resp = await _postJson(_homeUri('/users/me/change-password'), {
      'current_password': currentPassword,
      'new_password': newPassword,
    });
    _decodeOrThrow(resp);
  }

  /// Opaque security event relay — server sees only numeric [event] + target ids.
  Future<void> postSecuritySignal({
    required int event,
    required List<String> targets,
  }) async {
    final resp = await _postJson(_homeUri('/security-signals'), {
      'event': event,
      'targets': targets,
    });
    _decodeOrThrow(resp);
  }

  Future<List<DeviceInfo>> listMyDevices() async {
    final resp = await _get(_homeUri('/users/me/devices'));
    final list = _decodeOrThrow(resp) as List<dynamic>;
    return list.map((e) => DeviceInfo.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> revokeOtherDevices() async {
    final resp = await _delete(_homeUri('/users/me/devices/others'));
    _decodeOrThrow(resp);
  }

  Future<void> revokeDevice(String deviceId) async {
    final resp = await _delete(_homeUri('/users/me/devices/$deviceId'));
    _decodeOrThrow(resp);
  }
}
