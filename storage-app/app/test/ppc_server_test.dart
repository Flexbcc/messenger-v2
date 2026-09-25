// storage-app :: тесты ПК-сервера (WIRE.md).
// Полный цикл pairing→PUT→GET→STAT→DELETE→usage, плюс негативы:
// 401 (неподписанный/чужой), 422 (integrity), 413 (quota), path-traversal.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:storage_app/app.dart';
import 'package:storage_app/models/models.dart';

/// Тестовый пир: Ed25519-ключи + подпись запросов по WIRE.md.
class TestPeer {
  final SimpleKeyPair keyPair;
  final List<int> pub;
  final String nodeId;
  static final _algo = Ed25519();

  TestPeer._(this.keyPair, this.pub, this.nodeId);

  static Future<TestPeer> create(String nodeId) async {
    final kp = await _algo.newKeyPair();
    final pub = await kp.extractPublicKey();
    return TestPeer._(kp, pub.bytes, nodeId);
  }

  String get pubkeyStr => 'ed25519:${base64.encode(pub)}';

  Future<Map<String, String>> signHeaders(
      String method, Uri uri, List<int> body) async {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final path = uri.query.isEmpty ? uri.path : '${uri.path}?${uri.query}';
    final bodyHash = sha256.convert(body).toString();
    final canonical = utf8.encode('$method\n$path\n$ts\n$bodyHash');
    final sig = await _algo.sign(canonical, keyPair: keyPair);
    return {
      'X-PPC-Node-Id': nodeId,
      'X-PPC-Pubkey': pubkeyStr,
      'X-PPC-Timestamp': '$ts',
      'X-PPC-Signature': base64.encode(sig.bytes),
    };
  }
}

/// Мини HTTP-клиент к серверу.
class Client {
  final int port;
  final HttpClient _c = HttpClient();
  Client(this.port);

  Future<({int status, Uint8List body})> send(
    String method,
    String path, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    final uri = Uri.parse('http://127.0.0.1:$port$path');
    final req = await _c.openUrl(method, uri);
    headers?.forEach(req.headers.set);
    if (body != null) req.add(body);
    final resp = await req.close();
    final bytes = <int>[];
    await for (final c in resp) {
      bytes.addAll(c);
    }
    return (status: resp.statusCode, body: Uint8List.fromList(bytes));
  }

  void close() => _c.close(force: true);
}

Map<String, Object?> jsonOf(Uint8List b) =>
    jsonDecode(utf8.decode(b)) as Map<String, Object?>;

String sha256Hex(List<int> b) => sha256.convert(b).toString();

void main() {
  late Directory tmp;
  late StorageApp app;
  late Client client;
  late TestPeer peer;
  const userId = 'user-abc';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ppc_test_');
    final config = StorageConfig(
      allowedRoot: tmp.path,
      port: 0, // случайный свободный порт
      host: '127.0.0.1',
      maxBytes: 0,
    );
    app = await StorageApp.bootstrap(config);
    await app.start();
    client = Client(app.server.port);
    peer = await TestPeer.create(userId);
  });

  tearDown(() async {
    client.close();
    await app.shutdown();
    await tmp.delete(recursive: true);
  });

  Future<void> pair() async {
    app.pairing.registerCode('123456');
    final body = utf8.encode(jsonEncode({
      'code': '123456',
      'peer_pubkey': peer.pubkeyStr,
      'node_id': peer.nodeId,
      'name': 'test-node',
    }));
    final r = await client.send('POST', '/ppc/pair',
        headers: {'content-type': 'application/json'}, body: body);
    expect(r.status, 200);
    final j = jsonOf(r.body);
    expect(j['storage_pubkey'], startsWith('ed25519:'));
  }

  test('health без подписи', () async {
    final r = await client.send('GET', '/ppc/health');
    expect(r.status, 200);
    expect(jsonOf(r.body)['status'], 'ok');
  });

  test('полный цикл: pair → PUT → GET → STAT → DELETE → usage', () async {
    await pair();
    final content = Uint8List.fromList(utf8.encode('ciphertext-payload-123'));
    final hash = sha256Hex(content);
    final path = '/ppc/blob/$userId/$hash';

    // PUT
    var h = await peer.signHeaders('PUT', Uri.parse(path), content);
    var r = await client.send('PUT', path, headers: h, body: content);
    expect(r.status, 200);
    expect(jsonOf(r.body)['size'], content.length);

    // Идемпотентный повтор PUT
    h = await peer.signHeaders('PUT', Uri.parse(path), content);
    r = await client.send('PUT', path, headers: h, body: content);
    expect(r.status, 200);

    // GET
    h = await peer.signHeaders('GET', Uri.parse(path), const []);
    r = await client.send('GET', path, headers: h);
    expect(r.status, 200);
    expect(r.body, content);

    // STAT
    final statPath = '/ppc/stat/$userId/$hash';
    h = await peer.signHeaders('GET', Uri.parse(statPath), const []);
    r = await client.send('GET', statPath, headers: h);
    expect(r.status, 200);
    var j = jsonOf(r.body);
    expect(j['exists'], true);
    expect(j['size'], content.length);

    // usage
    final usagePath = '/ppc/usage?user_id=$userId';
    h = await peer.signHeaders('GET', Uri.parse(usagePath), const []);
    r = await client.send('GET', usagePath, headers: h);
    expect(r.status, 200);
    j = jsonOf(r.body);
    expect(j['used_files'], 1);
    expect(j['used_bytes'], content.length);

    // DELETE (refcount was 2 after idempotent PUT → one decrement)
    h = await peer.signHeaders('DELETE', Uri.parse(path), const []);
    r = await client.send('DELETE', path, headers: h);
    expect(r.status, 200);

    // Second DELETE — refcount 0, file removed
    h = await peer.signHeaders('DELETE', Uri.parse(path), const []);
    r = await client.send('DELETE', path, headers: h);
    expect(r.status, 200);
    expect(jsonOf(r.body)['ok'], true);

    // DELETE снова — идемпотентно 200
    h = await peer.signHeaders('DELETE', Uri.parse(path), const []);
    r = await client.send('DELETE', path, headers: h);
    expect(r.status, 200);

    // STAT после удаления — 404
    h = await peer.signHeaders('GET', Uri.parse(statPath), const []);
    r = await client.send('GET', statPath, headers: h);
    expect(r.status, 404);

    // usage обнулилась
    h = await peer.signHeaders('GET', Uri.parse(usagePath), const []);
    r = await client.send('GET', usagePath, headers: h);
    j = jsonOf(r.body);
    expect(j['used_files'], 0);
    expect(j['used_bytes'], 0);
  });

  test('неподписанный запрос → 401', () async {
    await pair();
    final content = Uint8List.fromList(utf8.encode('x'));
    final hash = sha256Hex(content);
    final r = await client.send('PUT', '/ppc/blob/$userId/$hash',
        body: content);
    expect(r.status, 401);
    expect(jsonOf(r.body)['error'], 'unauthorized');
  });

  test('чужой (не сопряжённый) ключ → 401', () async {
    await pair();
    final stranger = await TestPeer.create(userId);
    final content = Uint8List.fromList(utf8.encode('y'));
    final hash = sha256Hex(content);
    final path = '/ppc/blob/$userId/$hash';
    final h = await stranger.signHeaders('PUT', Uri.parse(path), content);
    final r = await client.send('PUT', path, headers: h, body: content);
    expect(r.status, 401);
  });

  test('integrity: sha256(body) != hash → 422', () async {
    await pair();
    final content = Uint8List.fromList(utf8.encode('real-content'));
    final wrongHash = sha256Hex(utf8.encode('other-content'));
    final path = '/ppc/blob/$userId/$wrongHash';
    final h = await peer.signHeaders('PUT', Uri.parse(path), content);
    final r = await client.send('PUT', path, headers: h, body: content);
    expect(r.status, 422);
    expect(jsonOf(r.body)['error'], 'integrity');
  });

  test('квота: превышение per-user → 413 quota_exceeded', () async {
    // Пэйрим и вручную ставим маленькую квоту для user.
    await pair();
    app.metaDb.upsertPeer(Peer(
      userUuid: userId,
      pubkey: peer.pubkeyStr,
      name: 'test-node',
      addedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      quotaBytes: 10,
    ));
    final content = Uint8List.fromList(List.filled(50, 65)); // 50 байт > 10
    final hash = sha256Hex(content);
    final path = '/ppc/blob/$userId/$hash';
    final h = await peer.signHeaders('PUT', Uri.parse(path), content);
    final r = await client.send('PUT', path, headers: h, body: content);
    expect(r.status, 413);
    expect(jsonOf(r.body)['error'], 'quota_exceeded');
  });

  test('path-traversal в user_id отклонён (не 200)', () async {
    await pair();
    final content = Uint8List.fromList(utf8.encode('z'));
    final hash = sha256Hex(content);
    // %2e%2e%2f = ../ — пытаемся выйти из allowed_root.
    final path = '/ppc/blob/..%2f..%2fetc/$hash';
    final uri = Uri.parse('http://127.0.0.1:${app.server.port}$path');
    final h = await peer.signHeaders('PUT', uri, content);
    final r = await client.send('PUT', path, headers: h, body: content);
    expect(r.status, isNot(200));
    // Никакой файл не создан вне корня.
    expect(File('/etc/$hash').existsSync(), false);
  });

  test('traversal: сегментированный user_id с .. → отклонён', () async {
    await pair();
    final content = Uint8List.fromList(utf8.encode('w'));
    final hash = sha256Hex(content);
    // Прямая проверка BlobStore на traversal-паттерн.
    expect(
      () => app.blobStore.blobPath('..', hash),
      throwsA(isA<Object>()),
    );
    expect(
      () => app.blobStore.blobPath('a/b', hash),
      throwsA(isA<Object>()),
    );
    // Санити: валидный адрес не кидает и внутри корня.
    final ok = app.blobStore.blobPath(userId, hash);
    expect(p.isWithin(tmp.absolute.path, ok), true);
  });
}
