import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

/// Real LAN simulation of a phone pairing with the running OUO Storage app.
/// The PC receives ciphertext only; the virtual phone keeps attachment keys.
Future<void> main() async {
  final raw = Platform.environment['OUO_PPC_QR_JSON'];
  if (raw == null || raw.isEmpty) {
    stderr.writeln('OUO_PPC_QR_JSON is required');
    exitCode = 64;
    return;
  }
  final payload = jsonDecode(raw) as Map<String, dynamic>;
  final reach = payload['reach'] as Map<String, dynamic>;
  final hosts = (reach['lan'] as List).cast<String>();
  final port = reach['port'] as int;
  final base = Uri.parse('http://${hosts.first}:$port');

  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final pubkey = 'ed25519:${base64Encode(publicKey.bytes)}';
  final userId = Platform.environment['OUO_PPC_USER_ID'] ?? 'demo-phone-user';
  final pin = Platform.environment['OUO_PPC_PIN'];

  final pairBody = utf8.encode(jsonEncode({
    'code': payload['code'],
    if (pin == null || pin.isEmpty) 'qr_secret': payload['qr_secret'],
    if (pin != null && pin.isNotEmpty) 'pin': pin,
    'peer_pubkey': pubkey,
    'node_id': userId,
    'name': 'Виртуальный телефон',
  }));
  final pair = await _request(
    base.resolve('/ppc/pair'),
    'POST',
    pairBody,
    {'Content-Type': 'application/json'},
  );
  _require(pair.status == 200, 'pair failed: HTTP ${pair.status}');

  final samples = <({String name, String mime, Uint8List bytes})>[
    (
      name: 'photo.png',
      mime: 'image/png',
      bytes: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    ),
    (
      name: 'document.txt',
      mime: 'text/plain',
      bytes: Uint8List.fromList(utf8.encode('OUO private document demo')),
    ),
  ];

  for (final sample in samples) {
    final encrypted =
        await _encrypt(sample.bytes, filename: sample.name, mime: sample.mime);
    _require(!_same(encrypted.ciphertext, sample.bytes),
        'ciphertext equals plaintext');
    final hash = sha256.convert(encrypted.ciphertext).toString();
    final path = '/ppc/blob/$userId/$hash';

    final putHeaders = await _signedHeaders(
      algorithm,
      keyPair,
      pubkey,
      userId,
      'PUT',
      path,
      encrypted.ciphertext,
    );
    final put = await _request(
      base.resolve(path),
      'PUT',
      encrypted.ciphertext,
      putHeaders,
    );
    _require(put.status == 200, 'upload failed: HTTP ${put.status}');

    final getHeaders = await _signedHeaders(
      algorithm,
      keyPair,
      pubkey,
      userId,
      'GET',
      path,
      const [],
    );
    final get = await _request(base.resolve(path), 'GET', const [], getHeaders);
    _require(get.status == 200, 'download failed: HTTP ${get.status}');
    _require(_same(get.body, encrypted.ciphertext), 'ciphertext changed');
    final opened = await _decrypt(get.body, encrypted.pointer);
    _require(_same(opened, sample.bytes), 'phone decrypt failed');

    stdout.writeln(
      'LIVE_PPC_OK ${sample.name} plaintext=${sample.bytes.length} '
      'ciphertext=${encrypted.ciphertext.length} hash=$hash',
    );
  }
}

Future<({Uint8List ciphertext, Map<String, Object> pointer})> _encrypt(
  Uint8List plaintext, {
  required String filename,
  required String mime,
}) async {
  final aes = AesGcm.with256bits();
  final key = await aes.newSecretKey();
  final nonce = aes.newNonce();
  final box = await aes.encrypt(plaintext, secretKey: key, nonce: nonce);
  return (
    ciphertext:
        Uint8List.fromList([...box.nonce, ...box.cipherText, ...box.mac.bytes]),
    pointer: {
      'key': base64Encode(await key.extractBytes()),
      'filename': filename,
      'mime': mime,
      'size': plaintext.length,
    },
  );
}

Future<Uint8List> _decrypt(
    List<int> ciphertext, Map<String, Object> pointer) async {
  final nonce = ciphertext.sublist(0, 12);
  final mac = ciphertext.sublist(ciphertext.length - 16);
  final body = ciphertext.sublist(12, ciphertext.length - 16);
  final plain = await AesGcm.with256bits().decrypt(
    SecretBox(body, nonce: nonce, mac: Mac(mac)),
    secretKey: SecretKey(base64Decode(pointer['key']! as String)),
  );
  return Uint8List.fromList(plain);
}

Future<Map<String, String>> _signedHeaders(
  Ed25519 algorithm,
  SimpleKeyPair keyPair,
  String pubkey,
  String nodeId,
  String method,
  String path,
  List<int> body,
) async {
  final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final digest = sha256.convert(body).toString();
  final canonical = utf8.encode('$method\n$path\n$timestamp\n$digest');
  final signature = await algorithm.sign(canonical, keyPair: keyPair);
  return {
    'X-PPC-Node-Id': nodeId,
    'X-PPC-Pubkey': pubkey,
    'X-PPC-Timestamp': '$timestamp',
    'X-PPC-Signature': base64Encode(signature.bytes),
    'Content-Type': 'application/octet-stream',
  };
}

Future<({int status, Uint8List body})> _request(
  Uri uri,
  String method,
  List<int> body,
  Map<String, String> headers,
) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    headers.forEach(request.headers.set);
    if (body.isNotEmpty) request.add(body);
    final response = await request.close();
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return (status: response.statusCode, body: Uint8List.fromList(bytes));
  } finally {
    client.close(force: true);
  }
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

bool _same(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}
