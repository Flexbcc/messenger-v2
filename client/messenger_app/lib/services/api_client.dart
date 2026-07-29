import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as _crypto;
import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/device_info.dart';
import 'network_usage_store.dart';

/// PoW solver (Task #69) — запускается в Isolate через compute().
/// Ищет nonce: sha256("$challenge:$nonce").hex() начинается с [difficulty] нулей.
/// Использует минимальный pure-Dart SHA-256 чтобы не зависеть от async API.
String _solvePowIsolate(Map<String, dynamic> args) {
  final challenge = args['challenge'] as String;
  final difficulty = (args['difficulty'] as int?) ?? 0;
  if (difficulty == 0) return '0';
  final prefix = '0' * difficulty;
  var nonce = 0;
  while (true) {
    final input = '$challenge:$nonce';
    final hash = _sha256Hex(utf8.encode(input));
    if (hash.startsWith(prefix)) return '$nonce';
    nonce++;
  }
}

/// SHA-256 через package:crypto (pure-Dart, синхронный).
String _sha256Hex(List<int> data) {
  return _crypto.sha256.convert(data).toString();
}

/// Результат GET /conversations/{id}/messages (бэкенд ≥ v0.46 — MessagePage).
class MessagePageResult {
  const MessagePageResult({
    required this.items,
    required this.hasMore,
    this.nextCursor,
  });
  final List<dynamic> items;
  final bool hasMore;
  final String? nextCursor; // ISO datetime для следующего before=
}

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

  Future<http.Response> _post(Uri uri) async => http.post(uri, headers: _headers);

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
  /// Task #69: автоматически решает PoW если сервер требует (difficulty > 0).
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
    // PoW (Task #69): получаем challenge и решаем перед отправкой
    String? powChallenge;
    String? powNonce;
    try {
      final challengeResp = await getPowChallenge();
      final difficulty = (challengeResp['difficulty'] as int?) ?? 0;
      if (difficulty > 0) {
        powChallenge = challengeResp['challenge'] as String?;
        if (powChallenge != null) {
          powNonce = await solvePow(powChallenge, difficulty);
        }
      }
    } catch (_) {
      // Если PoW недоступен (старый сервер) — продолжаем без него
    }

    final body = <String, dynamic>{
      'display_name': displayName,
      'phone': phone,
      'login': login,
      'email': email,
      'password': password,
      'device_name': deviceName,
      'device_type': deviceType,
      'auth_public_key': authPublicKey,
      'identity_key_bundle': identityKeyBundle,
    };
    if (powChallenge != null) body['pow_challenge'] = powChallenge;
    if (powNonce != null) body['pow_nonce'] = powNonce;

    final resp = await _postJson(_homeUri('/auth/register'), body);
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

  // ---------------------------------------------------------------------------
  // Push token registration (Task #17 — push-proxy)
  // ---------------------------------------------------------------------------

  Uri _pushUri(String path) => Uri.parse('${AppConfig.pushProxyUrl}$path');

  /// Регистрирует push token на push-proxy.
  Future<void> registerPushToken({
    required String deviceId,
    required String platform,
    required String token,
  }) async {
    final resp = await _postJson(_pushUri('/tokens'), {
      'device_id': deviceId,
      'platform': platform,
      'token': token,
    });
    _decodeOrThrow(resp);
  }

  /// Удаляет push token при logout.
  Future<void> deletePushToken({required String deviceId}) async {
    final resp = await _delete(_pushUri('/tokens/$deviceId'));
    _decodeOrThrow(resp);
  }

  /// Инвалидирует текущий JWT на сервере (logout).
  /// Не бросает исключение при сетевой ошибке — токен всё равно удаляется локально.
  Future<void> logout() async {
    try {
      await _postJson(_homeUri('/auth/logout'), {});
    } catch (_) {
      // Лучший effort — локальный токен будет удалён в любом случае
    }
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

  Future<Map<String, dynamic>> updateDisplayName(String displayName) async {
    final resp = await _patchJson(_homeUri('/users/me'), {'display_name': displayName});
    return _decodeOrThrow(resp) as Map<String, dynamic>;
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
    final resp = await http.put(_homeUri('/users/me/profile'), headers: _headers, body: jsonEncode(body));
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getProfileSettings() async {
    final resp = await _get(_homeUri('/users/me/profile-settings'));
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  Future<void> updateProfileSettings(Map<String, dynamic> blob) async {
    final resp = await http.put(
      _homeUri('/users/me/profile-settings'),
      headers: _headers,
      body: jsonEncode(blob),
    );
    _decodeOrThrow(resp);
  }

  Future<Map<String, dynamic>> searchUserByLogin(String login) async {
    final resp = await _get(_discoveryUri('/registry/users/search?login=${Uri.encodeQueryComponent(login)}'));
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
    /// Per-device E2EE (Task #57): список [{device_id, ciphertext}].
    /// Если передан, сервер доставляет каждый конверт конкретному устройству.
    List<Map<String, String>>? deviceEnvelopes,
    /// Storage federation (Task #63): URL Media-node где лежат медиафайлы.
    /// Нужен чтобы получатели на других Home-node могли скачать медиа.
    String? mediaNodeUrl,
    /// Список media_id загруженных файлов (для federation маппинга).
    List<String>? mediaIds,
  }) async {
    final body = <String, dynamic>{
      'ciphertext': ciphertext,
      'content_type': contentType,
      'crypto_version': cryptoVersion,
      'client_msg_id': clientMsgId,
    };
    if (deviceEnvelopes != null && deviceEnvelopes.isNotEmpty) {
      body['device_envelopes'] = deviceEnvelopes;
    }
    if (mediaNodeUrl != null) {
      body['media_node_url'] = mediaNodeUrl;
    }
    if (mediaIds != null && mediaIds.isNotEmpty) {
      body['media_ids'] = mediaIds;
    }
    final resp = await _postJson(_homeUri('/conversations/$conversationId/messages'), body);
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  /// Получить устройства пользователя для per-device E2EE шифрования.
  Future<List<Map<String, dynamic>>> getUserDevices(String userId) async {
    final resp = await _get(_homeUri('/users/$userId/devices'));
    final list = _decodeOrThrow(resp) as List<dynamic>;
    return list.cast<Map<String, dynamic>>();
  }

  /// Возвращает страницу сообщений. Бэкенд отдаёт MessagePage:
  ///   { items: [...], has_more: bool, next_cursor: str? }
  /// Для обратной совместимости (старый сервер вернёт List) — graceful fallback.
  Future<MessagePageResult> getMessages(
    String conversationId, {
    int limit = 50,
    String? before,
    String? after,
  }) async {
    final query = {
      'limit': '$limit',
      if (before != null) 'before': before,
      if (after != null) 'after': after,
    };
    final uri = _homeUri('/conversations/$conversationId/messages').replace(queryParameters: query);
    final resp = await _get(uri);
    final decoded = _decodeOrThrow(resp);
    if (decoded is Map<String, dynamic>) {
      // Новый формат — MessagePage
      return MessagePageResult(
        items: List<dynamic>.from(decoded['items'] as List? ?? []),
        hasMore: decoded['has_more'] as bool? ?? false,
        nextCursor: decoded['next_cursor'] as String?,
      );
    }
    // Старый формат — просто список
    return MessagePageResult(items: List<dynamic>.from(decoded as List), hasMore: false);
  }

  /// Post-R5 e2e delivery ACK — recipient confirms it absorbed [packetId]
  /// into its local message list; see spec/0202_DELIVERY.md.
  Future<void> ackMessage(String conversationId, String packetId) async {
    final resp = await _post(_homeUri('/conversations/$conversationId/messages/$packetId/ack'));
    _decodeOrThrow(resp);
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

  /// Key Transparency Log (Task #67) — история смены ключей пользователя.
  /// Клиент проверяет что текущий ключ контакта совпадает с последним в логе.
  Future<Map<String, dynamic>> getUserKeyLog(String userId, {String? sinceId, int limit = 50}) async {
    final query = <String, String>{'limit': '$limit'};
    if (sinceId != null) query['since_id'] = sinceId;
    final uri = _homeUri('/users/$userId/key-log').replace(queryParameters: query);
    final resp = await _get(uri);
    return _decodeOrThrow(resp) as Map<String, dynamic>;
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

  /// Link the logged-in user to storage-app via QR JSON (Bearer auth).
  Future<Map<String, dynamic>> pairPersonalPc({
    required String payloadJson,
  }) async {
    final resp = await _postJson(_homeUri('/users/me/storage/personal-pc/pair'), {
      'payload': payloadJson,
    });
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  /// Owner panel: pair any user via monitor API (operator access).
  Future<Map<String, dynamic>> pairPersonalPcMonitor({
    required String userId,
    required String payloadJson,
  }) async {
    final resp = await _postJson(_homeUri('/monitor/storage/personal-pc/pair'), {
      'user_id': userId,
      'payload': payloadJson,
    });
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  // ---------------------------------------------------------------------------
  // Task #69 — Anti-spam PoW при регистрации
  // ---------------------------------------------------------------------------

  /// Получить PoW-challenge для регистрации.
  /// Возвращает { challenge, difficulty, ttl_seconds, algorithm }.
  /// Если difficulty=0 — PoW отключён, challenge можно не решать.
  Future<Map<String, dynamic>> getPowChallenge() async {
    final resp = await _get(_homeUri('/auth/pow-challenge'));
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  /// Решить PoW-challenge: найти nonce такой что
  /// sha256("$challenge:$nonce") начинается с [difficulty] нулей.
  /// Выполняется в Isolate-е чтобы не блокировать UI.
  static Future<String> solvePow(String challenge, int difficulty) async {
    return await compute(_solvePowIsolate, {'challenge': challenge, 'difficulty': difficulty});
  }

  // ---------------------------------------------------------------------------
  // Task #70 — Исчезающие сообщения
  // ---------------------------------------------------------------------------

  /// Установить TTL исчезающих сообщений для разговора.
  /// [ttlSeconds]=0 — отключить. Только участник может менять.
  Future<Map<String, dynamic>> setDisappearingTtl(
    String conversationId, {
    required int ttlSeconds,
  }) async {
    final resp = await _patchJson(
      _homeUri('/conversations/$conversationId/disappearing-ttl'),
      {'ttl_seconds': ttlSeconds},
    );
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }

  // ---------------------------------------------------------------------------
  // Task #71 — Редактирование сообщений
  // ---------------------------------------------------------------------------

  /// Отредактировать отправленное сообщение. Только отправитель, только в пределах окна.
  /// [newCiphertext] — новый зашифрованный текст.
  /// Ответ: обновлённый MessageResponse с edited_at != null.
  Future<Map<String, dynamic>> editMessage(
    String conversationId,
    String messageId,
    String newCiphertext,
  ) async {
    final resp = await _patchJson(
      _homeUri('/conversations/$conversationId/messages/$messageId'),
      {'new_ciphertext': newCiphertext},
    );
    return _decodeOrThrow(resp) as Map<String, dynamic>;
  }
}
