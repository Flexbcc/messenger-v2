import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/device_info.dart';
import '../models/attachment_pointer.dart';
import 'bootstrap_service.dart';
import 'debug_log.dart';
import 'network_usage_store.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() =>
      'ApiException($statusCode): ${DebugLog.redact(message, maximum: 1024)}';
}

/// Thin REST client for Home Node + Media Node. No retries/backoff here —
/// see spec/0202_DELIVERY.md for what a production transport layer owes;
/// this is intentionally the simple version (ADR-0004).
class ApiClient {
  ApiClient({this.accessToken});

  String? accessToken;
  final _networkUsage = NetworkUsageStore();
  static const _requestTimeout = Duration(seconds: 15);
  static const _mediaTimeout = Duration(seconds: 60);
  static const _maxJsonResponseBytes = 8 * 1024 * 1024;
  static const _maxMediaDownloadBytes = maxAttachmentCiphertextBytes;
  static final RegExp _mediaIdPattern = RegExp(r'^[0-9a-f]{64}$');

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (accessToken != null) 'Authorization': 'Bearer $accessToken',
  };

  Uri _homeUri(String path) => Uri.parse('${AppConfig.homeNodeUrl}$path');
  Uri _mediaUri(String path) => Uri.parse('${AppConfig.mediaNodeUrl}$path');
  Future<http.Response> _getFromDiscovery(
    String path, {
    Map<String, String>? queryParameters,
  }) async {
    Object? lastError;
    http.Response? lastResponse;
    for (final origin in AppConfig.discoveryNodeUrls) {
      final uri = Uri.parse(
        '$origin$path',
      ).replace(queryParameters: queryParameters);
      try {
        final response = await _get(uri);
        if (response.statusCode < 500) return response;
        lastResponse = response;
      } catch (error) {
        lastError = error;
      }
    }
    if (lastResponse != null) return lastResponse;
    throw lastError ?? StateError('Discovery sources are not configured');
  }

  String _pathSegment(String value, String name) {
    if (value.isEmpty ||
        value.length > 256 ||
        value.codeUnits.any((unit) => unit < 32 || unit == 127)) {
      throw ArgumentError.value(value, name, 'invalid URL path segment');
    }
    return Uri.encodeComponent(value);
  }

  Future<String> getWebPushVapidKey() async {
    final resp = await _get(_homeUri('/users/me/push/vapid-key'));
    final data = _decodeObject(resp);
    final publicKey = data['public_key'];
    if (publicKey is! String ||
        publicKey.length < 16 ||
        publicKey.length > 1024) {
      throw ApiException(502, 'server returned an invalid VAPID key');
    }
    return publicKey;
  }

  Future<void> registerWebPush(String subscription) async {
    final resp = await _putJson(_homeUri('/users/me/push'), {
      'subscription': subscription,
    });
    _decodeOrThrow(resp);
  }

  Future<void> deleteWebPush() async {
    final resp = await _delete(_homeUri('/users/me/push'));
    _decodeOrThrow(resp);
  }

  Future<void> _trackReceived(http.Response resp) async {
    await _trackReceivedBytes(resp.bodyBytes.length);
  }

  Future<void> _trackReceivedBytes(int bytes) async {
    try {
      await _networkUsage.recordReceived(bytes);
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

  Future<http.Response> _sendBounded(
    http.BaseRequest request, {
    Duration timeout = _requestTimeout,
    int maxBytes = _maxJsonResponseBytes,
  }) async {
    request
      ..followRedirects = false
      ..maxRedirects = 0;
    final client = http.Client();
    try {
      final streamed = await client.send(request).timeout(timeout);
      final declared = streamed.contentLength;
      if (declared != null && (declared < 0 || declared > maxBytes)) {
        throw ApiException(
          streamed.statusCode,
          'response body exceeds safety limit',
        );
      }
      final body = BytesBuilder(copy: false);
      var received = 0;
      await for (final chunk in streamed.stream.timeout(timeout)) {
        received += chunk.length;
        if (received > maxBytes) {
          throw ApiException(
            streamed.statusCode,
            'response body exceeds safety limit',
          );
        }
        body.add(chunk);
      }
      return http.Response.bytes(
        body.takeBytes(),
        streamed.statusCode,
        headers: streamed.headers,
        isRedirect: streamed.isRedirect,
        persistentConnection: streamed.persistentConnection,
        reasonPhrase: streamed.reasonPhrase,
        request: streamed.request,
      );
    } finally {
      client.close();
    }
  }

  Future<http.Response> _request(String method, Uri uri, {String? body}) {
    final request = http.Request(method, uri)..headers.addAll(_headers);
    if (body != null) request.body = body;
    return _sendBounded(request);
  }

  Future<http.Response> _postJson(Uri uri, Map<String, dynamic> body) async {
    final encoded = jsonEncode(body);
    await _trackSent(utf8.encode(encoded).length);
    return _request('POST', uri, body: encoded);
  }

  Future<http.Response> _patchJson(Uri uri, Map<String, dynamic> body) async {
    final encoded = jsonEncode(body);
    await _trackSent(utf8.encode(encoded).length);
    return _request('PATCH', uri, body: encoded);
  }

  Future<http.Response> _putJson(Uri uri, Map<String, dynamic> body) async {
    final encoded = jsonEncode(body);
    await _trackSent(utf8.encode(encoded).length);
    return _request('PUT', uri, body: encoded);
  }

  Future<http.Response> _get(Uri uri) => _request('GET', uri);

  Future<http.Response> _post(Uri uri) => _request('POST', uri);

  Future<http.Response> _delete(Uri uri) => _request('DELETE', uri);

  dynamic _decodeOrThrow(http.Response resp) {
    if (resp.bodyBytes.length > _maxJsonResponseBytes) {
      throw ApiException(resp.statusCode, 'response body exceeds safety limit');
    }
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      unawaited(_trackReceived(resp));
      if (resp.body.isEmpty) return null;
      return jsonDecode(resp.body);
    }
    String message = resp.body.length > 4096
        ? '${resp.body.substring(0, 4096)}…'
        : resp.body;
    try {
      message =
          (jsonDecode(resp.body) as Map)['detail']?.toString() ?? resp.body;
    } catch (_) {}
    throw ApiException(resp.statusCode, message);
  }

  List<Map<String, dynamic>> _decodeObjectList(
    http.Response response, {
    required int maxItems,
  }) {
    final decoded = _decodeOrThrow(response);
    if (decoded is! List || decoded.length > maxItems) {
      throw ApiException(502, 'server returned an invalid list');
    }
    final result = <Map<String, dynamic>>[];
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) {
        throw ApiException(502, 'server returned an invalid list item');
      }
      result.add(item);
    }
    return List.unmodifiable(result);
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    final decoded = _decodeOrThrow(response);
    if (decoded is! Map<String, dynamic>) {
      throw ApiException(502, 'server returned an invalid object');
    }
    return decoded;
  }

  /// ADR-0007 temporary bridge: phone required, login/email optional, password.
  Future<Map<String, dynamic>> register({
    required String displayName,
    required String phone,
    String? login,
    String? email,
    String? password,
    required String deviceName,
    required String deviceType,
    required String authPublicKey,
    required Map<String, dynamic> identityKeyBundle,
  }) async {
    final pow = await _solveRegistrationPow();
    final resp = await _postJson(_homeUri('/auth/register'), {
      'display_name': displayName,
      'phone': phone,
      'login': login,
      'email': email,
      if (password != null) 'password': password,
      'device_name': deviceName,
      'device_type': deviceType,
      'auth_public_key': authPublicKey,
      'identity_key_bundle': identityKeyBundle,
      'pow_challenge': pow.$1,
      'pow_nonce': pow.$2,
    });
    return _decodeObject(resp);
  }

  Future<(String, String)> _solveRegistrationPow() async {
    final response = await _get(_homeUri('/auth/pow-challenge'));
    final payload = _decodeObject(response);
    final challenge = payload['challenge'];
    final difficulty = payload['difficulty'];
    if (challenge is! String ||
        challenge.length < 16 ||
        challenge.length > 256 ||
        difficulty is! int ||
        difficulty < 0 ||
        difficulty > 6) {
      throw ApiException(502, 'server returned an invalid PoW challenge');
    }
    if (difficulty <= 0) return ('', '');
    final prefix = '0' * difficulty;
    const maxAttempts = 50 * 1000 * 1000;
    for (var nonce = 0; nonce < maxAttempts; nonce++) {
      final value = nonce.toString();
      final digest = hashes.sha256.convert(utf8.encode('$challenge:$value'));
      if (digest.toString().startsWith(prefix)) return (challenge, value);
      if (nonce > 0 && nonce % 25000 == 0) {
        // Let the browser render while solving a deliberately small Hashcash.
        await Future<void>.delayed(Duration.zero);
      }
    }
    throw ApiException(503, 'registration PoW attempt limit exceeded');
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
    return _decodeObject(resp);
  }

  Future<Map<String, dynamic>> challenge(String deviceId) async {
    final resp = await _postJson(_homeUri('/auth/challenge'), {
      'device_id': deviceId,
    });
    return _decodeObject(resp);
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
    return _decodeObject(resp);
  }

  Future<Map<String, dynamic>> createDeviceLink({
    required String deviceName,
    required String deviceType,
    required String authPublicKey,
    required Map<String, dynamic> identityKeyBundle,
  }) async {
    final resp = await _postJson(_homeUri('/auth/device-links'), {
      'device_name': deviceName,
      'device_type': deviceType,
      'auth_public_key': authPublicKey,
      'identity_key_bundle': identityKeyBundle,
    });
    return _decodeObject(resp);
  }

  Future<Map<String, dynamic>> pollDeviceLink({
    required String linkId,
    required String secret,
  }) async {
    final encodedLinkId = Uri.encodeComponent(linkId);
    final resp = await _postJson(
      _homeUri('/auth/device-links/$encodedLinkId/poll'),
      {'secret': secret},
    );
    return _decodeObject(resp);
  }

  Future<void> approveDeviceLink({
    required String linkId,
    required String secret,
  }) async {
    final encodedLinkId = Uri.encodeComponent(linkId);
    final resp = await _postJson(
      _homeUri('/auth/device-links/$encodedLinkId/approve'),
      {'secret': secret},
    );
    _decodeOrThrow(resp);
  }

  Future<Map<String, dynamic>> inspectDeviceLink({
    required String linkId,
    required String secret,
  }) async {
    final encodedLinkId = Uri.encodeComponent(linkId);
    final resp = await _postJson(
      _homeUri('/auth/device-links/$encodedLinkId/inspect'),
      {'secret': secret},
    );
    return _decodeObject(resp);
  }

  Future<Map<String, dynamic>> getMyProfile() async {
    final resp = await _get(_homeUri('/users/me'));
    return _decodeObject(resp);
  }

  Future<Map<String, dynamic>> updateDisplayName(String displayName) async {
    final resp = await _patchJson(_homeUri('/users/me'), {
      'display_name': displayName,
    });
    return _decodeObject(resp);
  }

  Future<Map<String, dynamic>> updateProfile({
    String? displayName,
    String? login,
    String? email,
    String? phone,
    String? bio,
  }) async {
    final body = <String, dynamic>{};
    if (displayName != null) body['display_name'] = displayName;
    if (login != null) body['login'] = login;
    if (email != null) body['email'] = email;
    if (phone != null) body['phone'] = phone;
    if (bio != null) body['bio'] = bio;
    final resp = await _putJson(_homeUri('/users/me/profile'), body);
    return _decodeObject(resp);
  }

  Future<Map<String, dynamic>> getProfileSettings() async {
    final resp = await _get(_homeUri('/users/me/profile-settings'));
    return _decodeObject(resp);
  }

  Future<void> updateProfileSettings(Map<String, dynamic> blob) async {
    final resp = await _putJson(_homeUri('/users/me/profile-settings'), blob);
    _decodeOrThrow(resp);
  }

  Future<void> updatePresencePolicy({
    required bool onlineStatus,
    required String lastSeen,
    required List<String> selectedUserIds,
    required bool invisible,
  }) async {
    final body = {
      'online_status': onlineStatus,
      'last_seen': lastSeen,
      'selected_user_ids': selectedUserIds,
      'invisible': invisible,
    };
    final resp = await _putJson(_homeUri('/users/me/presence-policy'), body);
    _decodeOrThrow(resp);
  }

  Future<Map<String, dynamic>> getPresence(String userId) async {
    final id = _pathSegment(userId, 'userId');
    final resp = await _get(_homeUri('/users/$id/presence'));
    return _decodeObject(resp);
  }

  Future<Map<String, dynamic>> searchUserByLogin(String login) async {
    final resp = await _getFromDiscovery(
      '/registry/users/search',
      queryParameters: {'login': login},
    );
    return _decodeObject(resp);
  }

  Future<Map<String, dynamic>> getDiscoveryUserRecord(String userId) async {
    final id = _pathSegment(userId, 'userId');
    final resp = await _getFromDiscovery('/registry/users/$id');
    return _decodeObject(resp);
  }

  Future<Map<String, dynamic>> getPreKeyBundle(String userId) async {
    final id = _pathSegment(userId, 'userId');
    final resp = await _get(_homeUri('/users/$id/prekey-bundle'));
    return _decodeObject(resp);
  }

  Future<List<Map<String, dynamic>>> getUserDeviceBundles(
    String userId, {
    String? excludeDeviceId,
  }) async {
    final id = _pathSegment(userId, 'userId');
    final uri = _homeUri('/users/$id/devices').replace(
      queryParameters: {
        if (excludeDeviceId != null) 'exclude_device_id': excludeDeviceId,
      },
    );
    final resp = await _get(uri);
    return _decodeObjectList(resp, maxItems: 512);
  }

  Future<Map<String, dynamic>> getDevicePreKeyBundle(
    String userId,
    String deviceId,
  ) async {
    final encodedUserId = _pathSegment(userId, 'userId');
    final encodedDeviceId = _pathSegment(deviceId, 'deviceId');
    final resp = await _get(
      _homeUri('/users/$encodedUserId/devices/$encodedDeviceId/prekey-bundle'),
    );
    final data = _decodeObject(resp);
    final bundle = data['bundle'];
    if (bundle is! Map<String, dynamic>) {
      throw ApiException(502, 'server returned an invalid pre-key bundle');
    }
    return bundle;
  }

  Future<void> publishIdentityBundle(
    String deviceId,
    Map<String, dynamic> bundle,
  ) async {
    final id = _pathSegment(deviceId, 'deviceId');
    final resp = await _putJson(_homeUri('/devices/$id/identity-bundle'), {
      'identity_key_bundle': bundle,
    });
    _decodeOrThrow(resp);
  }

  Future<List<Map<String, dynamic>>> listConversations() async {
    final resp = await _get(_homeUri('/conversations'));
    return _decodeObjectList(resp, maxItems: 10000);
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
    return _decodeObject(resp);
  }

  Future<Map<String, dynamic>> sendMessage({
    required String conversationId,
    required String ciphertext,
    required String contentType,
    String cryptoVersion = 'signal-v1',
    String? clientMsgId,
    List<Map<String, String>>? deviceEnvelopes,
  }) async {
    final id = _pathSegment(conversationId, 'conversationId');
    final resp = await _postJson(_homeUri('/conversations/$id/messages'), {
      'ciphertext': ciphertext,
      'content_type': contentType,
      'crypto_version': cryptoVersion,
      'client_msg_id': clientMsgId,
      if (deviceEnvelopes != null && deviceEnvelopes.isNotEmpty)
        'device_envelopes': deviceEnvelopes,
    });
    return _decodeObject(resp);
  }

  Future<List<Map<String, dynamic>>> getMessages(
    String conversationId, {
    int limit = 50,
    String? before,
    String? after,
  }) async {
    final id = _pathSegment(conversationId, 'conversationId');
    if (limit < 1 || limit > 200) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 200');
    }
    if ((before?.length ?? 0) > 128 || (after?.length ?? 0) > 128) {
      throw const FormatException('invalid message cursor');
    }
    final query = {
      'limit': '$limit',
      if (before != null) 'before': before,
      if (after != null) 'after': after,
    };
    final uri = _homeUri(
      '/conversations/$id/messages',
    ).replace(queryParameters: query);
    final resp = await _get(uri);
    final page = _decodeObject(resp);
    final items = page['items'];
    if (items is! List || items.length > limit) {
      throw ApiException(502, 'server returned an invalid message page');
    }
    final result = <Map<String, dynamic>>[];
    for (final item in items) {
      if (item is! Map<String, dynamic>) {
        throw ApiException(502, 'server returned an invalid message item');
      }
      result.add(item);
    }
    return List.unmodifiable(result);
  }

  /// Post-R5 e2e delivery ACK — recipient confirms it absorbed [packetId]
  /// into its local message list; see spec/0202_DELIVERY.md.
  Future<void> ackMessage(String conversationId, String packetId) async {
    final conversation = _pathSegment(conversationId, 'conversationId');
    final packet = _pathSegment(packetId, 'packetId');
    final resp = await _post(
      _homeUri('/conversations/$conversation/messages/$packet/ack'),
    );
    _decodeOrThrow(resp);
  }

  /// Uploads an already E2EE-encrypted attachment to the relay buffer.
  ///
  /// `network_cache` is deliberate: Media Node must only retain a temporary
  /// delivery copy. Durable plaintext ownership stays on participants'
  /// devices; the server never receives the attachment key.
  Future<String> uploadMedia(
    Uint8List bytes,
    String filename, {
    String tier = 'network_cache',
  }) async {
    await _trackSent(bytes.length);
    final headers = <String, String>{};
    if (accessToken != null) headers['Authorization'] = 'Bearer $accessToken';
    final request = http.MultipartRequest('POST', _mediaUri('/media'))
      ..headers.addAll(headers)
      ..fields['tier'] = tier
      ..files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: filename),
      );
    final resp = await _sendBounded(request, timeout: _mediaTimeout);
    final data = _decodeObject(resp);
    final mediaId = data['media_id'];
    if (mediaId is! String || !_mediaIdPattern.hasMatch(mediaId)) {
      throw ApiException(502, 'media node returned an invalid media id');
    }
    final expectedId = hashes.sha256.convert(bytes).toString();
    if (mediaId != expectedId) {
      throw ApiException(502, 'media node returned a mismatched media id');
    }
    return mediaId;
  }

  /// Production path: JWT on Home Node → federation to Media Node.
  Future<Uint8List> downloadMedia(String mediaId) async {
    if (!_mediaIdPattern.hasMatch(mediaId)) {
      throw ArgumentError.value(mediaId, 'mediaId', 'invalid media id');
    }
    final headers = <String, String>{};
    if (accessToken != null) headers['Authorization'] = 'Bearer $accessToken';
    final client = http.Client();
    try {
      final request = http.Request('GET', _homeUri('/media/$mediaId'))
        ..headers.addAll(headers)
        ..followRedirects = false
        ..maxRedirects = 0;
      final streamed = await client.send(request).timeout(_mediaTimeout);
      if (streamed.statusCode != 200) {
        throw ApiException(streamed.statusCode, 'media download failed');
      }
      final declaredLength = streamed.contentLength;
      if (declaredLength != null &&
          (declaredLength < 0 || declaredLength > _maxMediaDownloadBytes)) {
        throw ApiException(413, 'media download exceeds safety limit');
      }

      final builder = BytesBuilder(copy: false);
      var received = 0;
      await for (final chunk in streamed.stream.timeout(_mediaTimeout)) {
        received += chunk.length;
        if (received > _maxMediaDownloadBytes) {
          throw ApiException(413, 'media download exceeds safety limit');
        }
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (hashes.sha256.convert(bytes).toString() != mediaId) {
        throw ApiException(502, 'media download failed integrity check');
      }
      unawaited(_trackReceivedBytes(bytes.length));
      return bytes;
    } finally {
      client.close();
    }
  }

  /// Nodes advertising [capability] (e.g. `'turn'`, `'relay'`) via Discovery
  /// Node — see spec/0604_DISCOVERY_NODE.md. Includes offline entries; the
  /// caller filters on `status`.
  Future<List<Map<String, dynamic>>> findNodes({
    required String capability,
  }) async {
    final resp = await _getFromDiscovery(
      '/registry/nodes',
      queryParameters: {'capability': capability},
    );
    final decoded = _decodeObject(resp);
    final nodes = decoded['nodes'];
    if (nodes is! List || nodes.length > 10000) {
      throw ApiException(502, 'Discovery returned an invalid node list');
    }
    final result = <Map<String, dynamic>>[];
    for (final node in nodes) {
      if (node is! Map<String, dynamic>) {
        throw ApiException(502, 'Discovery returned an invalid node');
      }
      result.add(node);
    }
    return List.unmodifiable(result);
  }

  /// Time-limited TURN credentials from a specific Turn Node — see
  /// spec/0605_TURN_NODE.md. [turnNodeUrl] comes from [findNodes].
  Future<Map<String, dynamic>> fetchTurnCredentials(String turnNodeUrl) async {
    final origin = validatedNetworkOrigin(turnNodeUrl, 'TURN Node URL');
    final request = http.Request('POST', Uri.parse('$origin/turn/credentials'))
      ..headers.addAll(_headers);
    final resp = await _sendBounded(request);
    return _decodeObject(resp);
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
    final list = _decodeObjectList(resp, maxItems: 512);
    return list.map(DeviceInfo.fromJson).toList(growable: false);
  }

  Future<void> revokeOtherDevices() async {
    final resp = await _delete(_homeUri('/users/me/devices/others'));
    _decodeOrThrow(resp);
  }

  Future<void> revokeDevice(String deviceId) async {
    final id = _pathSegment(deviceId, 'deviceId');
    final resp = await _delete(_homeUri('/users/me/devices/$id'));
    _decodeOrThrow(resp);
  }

  Future<void> setDeviceTrusted(String deviceId, bool trusted) async {
    final id = _pathSegment(deviceId, 'deviceId');
    final resp = await _patchJson(_homeUri('/users/me/devices/$id/trust'), {
      'trusted': trusted,
    });
    _decodeOrThrow(resp);
  }

  /// Link the logged-in user to storage-app via QR JSON (Bearer auth).
  Future<Map<String, dynamic>> pairPersonalPc({
    required String payloadJson,
  }) async {
    final resp = await _postJson(
      _homeUri('/users/me/storage/personal-pc/pair'),
      {'payload': payloadJson},
    );
    return _decodeObject(resp);
  }

  /// Owner panel: pair any user via monitor API (operator access).
  Future<Map<String, dynamic>> pairPersonalPcMonitor({
    required String userId,
    required String payloadJson,
  }) async {
    final resp = await _postJson(
      _homeUri('/monitor/storage/personal-pc/pair'),
      {'user_id': userId, 'payload': payloadJson},
    );
    return _decodeObject(resp);
  }
}
