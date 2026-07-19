// storage-app :: transport/server
// HTTP-сервер ПК-конца (dart:io HttpServer). Реализует РОВНО WIRE.md:
//   GET  /ppc/health
//   GET  /ppc/usage?user_id=U
//   PUT/GET/DELETE /ppc/blob/{user_id}/{hash}
//   GET  /ppc/stat/{user_id}/{hash}
//   POST /ppc/pair
//   POST /ppc/revoke
// Все подписанные эндпоинты проверяются по WIRE.md §Аутентификация.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/models.dart';
import '../pairing/keys.dart';
import '../pairing/pairing.dart';
import '../storage/blob_store.dart';
import '../storage/meta_db.dart';
import 'signature.dart';

class PpcServer {
  final StorageConfig config;
  final StorageKeys keys;
  final MetaDb metaDb;
  final BlobStore blobStore;
  final PairingManager pairing;
  final SignatureVerifier verifier;

  HttpServer? _http;

  PpcServer({
    required this.config,
    required this.keys,
    required this.metaDb,
    required this.blobStore,
    required this.pairing,
    SignatureVerifier? verifier,
  }) : verifier = verifier ?? SignatureVerifier();

  int get port => _http?.port ?? config.port;

  Future<void> start() async {
    _http = await HttpServer.bind(config.host, config.port);
    _http!.listen(_handle, onError: (Object e, StackTrace s) {
      stderr.writeln('server error: $e');
    });
  }

  Future<void> stop() async {
    await _http?.close(force: true);
    _http = null;
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      await _route(req);
    } catch (e, s) {
      stderr.writeln('unhandled: $e\n$s');
      await _json(req, HttpStatus.internalServerError,
          {'error': 'internal', 'detail': '$e'});
    }
  }

  Future<void> _route(HttpRequest req) async {
    final segs = req.uri.pathSegments;
    final method = req.method;

    // /ppc/health — без подписи.
    if (method == 'GET' && _match(segs, ['ppc', 'health'])) {
      return _json(req, HttpStatus.ok,
          {'status': 'ok', 'version': config.version});
    }

    // /ppc/pair — без подписи, защита кодом.
    if (method == 'POST' && _match(segs, ['ppc', 'pair'])) {
      return _handlePair(req);
    }

    // Остальное — читаем тело и проверяем подпись.
    final body = await _readBody(req);
    final auth = await _authenticate(req, body);
    if (auth != AuthResult.ok) {
      return _json(req, HttpStatus.unauthorized,
          {'error': 'unauthorized', 'detail': auth.name});
    }

    if (method == 'GET' && _match(segs, ['ppc', 'usage'])) {
      return _handleUsage(req);
    }
    if (method == 'POST' && _match(segs, ['ppc', 'revoke'])) {
      return _handleRevoke(req);
    }
    if (segs.length == 4 && segs[0] == 'ppc' && segs[1] == 'blob') {
      final userId = segs[2], hash = segs[3];
      switch (method) {
        case 'PUT':
          return _handlePut(req, userId, hash, body);
        case 'GET':
          return _handleGetBlob(req, userId, hash);
        case 'DELETE':
          return _handleDelete(req, userId, hash);
      }
    }
    if (method == 'GET' &&
        segs.length == 4 &&
        segs[0] == 'ppc' &&
        segs[1] == 'stat') {
      return _handleStat(req, segs[2], segs[3]);
    }

    return _json(req, HttpStatus.notFound,
        {'error': 'not_found', 'detail': 'no route'});
  }

  // ---- handlers ----

  Future<void> _handlePair(HttpRequest req) async {
    final body = await _readBody(req);
    Map<String, Object?> j;
    try {
      j = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
    } catch (_) {
      return _json(req, HttpStatus.badRequest,
          {'error': 'bad_request', 'detail': 'invalid json'});
    }
    final code = j['code'] as String?;
    final peerPubkey = j['peer_pubkey'] as String?;
    final nodeId = j['node_id'] as String?;
    final name = (j['name'] as String?) ?? '';
    if (code == null || peerPubkey == null || nodeId == null) {
      return _json(req, HttpStatus.badRequest,
          {'error': 'bad_request', 'detail': 'missing fields'});
    }
    final res = pairing.pair(
        code: code, peerPubkey: peerPubkey, nodeId: nodeId, name: name);
    switch (res) {
      case PairOk(:final storagePubkey):
        _audit(op: 'PAIR', result: 'ok', userUuid: nodeId, detail: name);
        return _json(req, HttpStatus.ok, {'storage_pubkey': storagePubkey});
      case PairBadCode():
        _audit(op: 'PAIR', result: 'bad_code', userUuid: nodeId);
        return _json(req, HttpStatus.forbidden,
            {'error': 'bad_code', 'detail': 'invalid or expired code'});
    }
  }

  Future<void> _handleUsage(HttpRequest req) async {
    final userId = req.uri.queryParameters['user_id'];
    if (userId == null || userId.isEmpty) {
      return _json(req, HttpStatus.badRequest,
          {'error': 'bad_request', 'detail': 'user_id required'});
    }
    final u = metaDb.userUsage(userId);
    final quota = _effectiveQuotaBytes(userId);
    return _json(
        req, HttpStatus.ok, Usage(u.bytes, u.files, quota).toJson());
  }

  /// Self-revoke: пир отзывает своё pairing (PAIRING.md). node_id = X-PPC-Node-Id.
  Future<void> _handleRevoke(HttpRequest req) async {
    final h = _extractHeaders(req);
    if (h == null) {
      return _json(req, HttpStatus.unauthorized,
          {'error': 'unauthorized', 'detail': 'missing headers'});
    }
    metaDb.revokePeer(h.nodeId);
    _audit(op: 'REVOKE', result: 'ok', userUuid: h.nodeId, detail: 'self');
    return _json(req, HttpStatus.ok, {'ok': true, 'revoked': h.nodeId});
  }

  Future<void> _handlePut(
      HttpRequest req, String userId, String hash, Uint8List body) async {
    // Валидация адреса (traversal/формат).
    try {
      blobStore.blobPath(userId, hash);
    } on InvalidAddressError catch (e) {
      return _json(req, HttpStatus.badRequest,
          {'error': 'bad_request', 'detail': e.message});
    }

    // Идемпотентность: уже есть → 200 без учёта квоты; refcount++.
    if (await blobStore.exists(userId, hash)) {
      final st = metaDb.statBlob(userId, hash);
      final size = st?.size ?? body.length;
      metaDb.insertBlob(
          userUuid: userId, hash: hash, size: size, now: _nowSec());
      return _json(req, HttpStatus.ok, {'ok': true, 'size': size});
    }

    // Квоты (SETTINGS.md §7, reject). Проверяем ДО записи.
    final over = _quotaExceeded(userId, body.length);
    if (over != null) {
      _audit(
          op: 'PUT', result: 'quota_exceeded', userUuid: userId, hash: hash,
          size: body.length, detail: over);
      return _json(req, HttpStatus.requestEntityTooLarge,
          {'error': 'quota_exceeded', 'detail': over});
    }

    try {
      final r = await blobStore.put(userId, hash, body);
      metaDb.insertBlob(
          userUuid: userId, hash: hash, size: r.size, now: _nowSec());
      _audit(
          op: 'PUT', result: 'ok', userUuid: userId, hash: hash, size: r.size);
      return _json(req, HttpStatus.ok, {'ok': true, 'size': r.size});
    } on IntegrityError catch (e) {
      _audit(
          op: 'PUT', result: 'integrity', userUuid: userId, hash: hash,
          detail: '$e');
      return _json(req, 422,
          {'error': 'integrity', 'detail': 'sha256(body)!=hash: $e'});
    }
  }

  Future<void> _handleGetBlob(
      HttpRequest req, String userId, String hash) async {
    final File? file;
    try {
      file = await blobStore.openBlobFile(userId, hash);
    } on InvalidAddressError {
      return _json(req, HttpStatus.notFound,
          {'error': 'not_found', 'detail': 'bad address'});
    }
    if (file == null) {
      return _json(req, HttpStatus.notFound,
          {'error': 'not_found', 'detail': 'blob'});
    }

    final fileSize = await file.length();
    metaDb.touchBlob(userId, hash, _nowSec());

    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
    final headers = req.response.headers;
    headers.contentType = ContentType('application', 'octet-stream');
    headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

    final int contentLength;
    if (rangeHeader != null && rangeHeader.isNotEmpty) {
      final range = _parseByteRange(rangeHeader, fileSize);
      if (range == null) {
        headers.set(HttpHeaders.contentRangeHeader, 'bytes */$fileSize');
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        _audit(
            op: 'GET',
            result: 'range',
            userUuid: userId,
            hash: hash,
            size: 0);
        await req.response.close();
        return;
      }
      contentLength = range.end - range.start + 1;
      req.response.statusCode = HttpStatus.partialContent;
      headers.contentLength = contentLength;
      headers.set(HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.end}/$fileSize');
      _audit(
          op: 'GET',
          result: 'ok',
          userUuid: userId,
          hash: hash,
          size: contentLength);
      await req.response.addStream(file.openRead(range.start, range.end + 1));
    } else {
      contentLength = fileSize;
      req.response.statusCode = HttpStatus.ok;
      headers.contentLength = contentLength;
      _audit(
          op: 'GET',
          result: 'ok',
          userUuid: userId,
          hash: hash,
          size: contentLength);
      await req.response.addStream(file.openRead());
    }
    await req.response.close();
  }

  /// Парсит `Range: bytes=…` (один диапазон). null → 416.
  ({int start, int end})? _parseByteRange(String header, int fileSize) {
    if (!header.startsWith('bytes=')) return null;
    final spec = header.substring(6).trim();
    if (spec.contains(',')) return null;

    final dash = spec.indexOf('-');
    if (dash < 0) return null;

    final startStr = spec.substring(0, dash);
    final endStr = spec.substring(dash + 1);

    late int start;
    late int end;

    if (startStr.isEmpty) {
      final suffix = int.tryParse(endStr);
      if (suffix == null || suffix <= 0) return null;
      if (suffix >= fileSize) {
        start = 0;
      } else {
        start = fileSize - suffix;
      }
      end = fileSize - 1;
    } else {
      start = int.tryParse(startStr) ?? -1;
      if (start < 0) return null;
      if (endStr.isEmpty) {
        end = fileSize - 1;
      } else {
        end = int.tryParse(endStr) ?? -1;
        if (end < 0) return null;
      }
    }

    if (start >= fileSize || end < start) return null;
    if (end >= fileSize) end = fileSize - 1;
    return (start: start, end: end);
  }

  Future<void> _handleDelete(
      HttpRequest req, String userId, String hash) async {
    // Идемпотентно: refcount--, файл только при refcount==0 (WIRE.md).
    final newRef = metaDb.decrementRef(userId, hash);
    if (newRef <= 0) {
      try {
        await blobStore.delete(userId, hash);
      } on InvalidAddressError {
        // некорректный адрес трактуем как «нечего удалять».
      }
    }
    _audit(op: 'DELETE', result: 'ok', userUuid: userId, hash: hash);
    return _json(req, HttpStatus.ok, {'ok': true});
  }

  Future<void> _handleStat(
      HttpRequest req, String userId, String hash) async {
    final bool ex;
    try {
      ex = await blobStore.exists(userId, hash);
    } on InvalidAddressError {
      return _json(req, HttpStatus.notFound,
          {'error': 'not_found', 'detail': 'bad address'});
    }
    if (!ex) {
      return _json(req, HttpStatus.notFound,
          {'error': 'not_found', 'detail': 'blob'});
    }
    final st = metaDb.statBlob(userId, hash);
    final size = st?.size ?? 0;
    return _json(req, HttpStatus.ok, {'exists': true, 'size': size});
  }

  // ---- auth / quota helpers ----

  Future<AuthResult> _authenticate(HttpRequest req, Uint8List body) async {
    final h = _extractHeaders(req);
    return verifier.verify(
      headers: h,
      method: req.method,
      uri: req.uri,
      body: body,
      isPaired: metaDb.isPaired,
    );
  }

  SignatureHeaders? _extractHeaders(HttpRequest req) {
    String? g(String n) => req.headers.value(n);
    final nodeId = g('X-PPC-Node-Id');
    final pubkey = g('X-PPC-Pubkey');
    final tsRaw = g('X-PPC-Timestamp');
    final sig = g('X-PPC-Signature');
    if (nodeId == null || pubkey == null || tsRaw == null || sig == null) {
      return null;
    }
    final ts = int.tryParse(tsRaw);
    if (ts == null) return null;
    return SignatureHeaders(
        nodeId: nodeId, pubkey: pubkey, timestamp: ts, signatureB64: sig);
  }

  /// Итоговая квота для отчёта usage: per-user (если задана) иначе глобальная.
  int _effectiveQuotaBytes(String userId) {
    final pq = metaDb.peerQuota(userId);
    if (pq != null && pq > 0) return pq;
    return config.maxBytes; // 0 = без лимита
  }

  /// Вернуть detail при переполнении, иначе null.
  String? _quotaExceeded(String userId, int addBytes) {
    // per-user
    final pq = metaDb.peerQuota(userId);
    final uu = metaDb.userUsage(userId);
    if (pq != null && pq > 0 && uu.bytes + addBytes > pq) {
      return 'per-user quota';
    }
    // глобальная
    if (config.maxBytes > 0) {
      final g = metaDb.globalUsage();
      if (g.bytes + addBytes > config.maxBytes) return 'global bytes quota';
    }
    if (config.maxFiles > 0) {
      final g = metaDb.globalUsage();
      if (g.files + 1 > config.maxFiles) return 'global files quota';
    }
    return null;
  }

  int _nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  void _audit({
    required String op,
    required String result,
    String? userUuid,
    String? hash,
    int size = 0,
    String detail = '',
  }) {
    metaDb.appendAudit(
      ts: _nowSec(),
      op: op,
      userUuid: userUuid,
      hash: hash,
      size: size,
      result: result,
      detail: detail,
    );
  }

  // ---- io helpers ----

  Future<Uint8List> _readBody(HttpRequest req) async {
    final chunks = <int>[];
    await for (final c in req) {
      chunks.addAll(c);
    }
    return Uint8List.fromList(chunks);
  }

  Future<void> _json(
      HttpRequest req, int status, Map<String, Object?> body) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  bool _match(List<String> segs, List<String> pat) {
    if (segs.length != pat.length) return false;
    for (var i = 0; i < segs.length; i++) {
      if (segs[i] != pat[i]) return false;
    }
    return true;
  }
}
