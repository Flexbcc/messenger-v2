library;

import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:storage_app/storage/meta_db_crypto.dart';

void main() {
  late Directory tmp;
  late List<int> key;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('meta_db_crypto_test_');
    key = List<int>.generate(32, (i) => i + 1);
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  Uint8List _sqliteHeader() {
    final b = Uint8List(100);
    const h = 'SQLite format 3';
    for (var i = 0; i < h.length; i++) {
      b[i] = h.codeUnitAt(i);
    }
    b[15] = 0;
    return b;
  }

  test('v1 roundtrip includes PPC1 magic', () async {
    final dbPath = p.join(tmp.path, 'meta.db');
    await File(dbPath).writeAsBytes(_sqliteHeader());

    await MetaDbCrypto.encryptDatabaseCopy(dbPath, key);
    final enc = await File('${dbPath}.enc').readAsBytes();
    expect(enc.sublist(0, 4), [0x50, 0x50, 0x43, 0x31]);
    expect(enc[4], 1);

    await MetaDbCrypto.decryptDatabaseFile('${dbPath}.enc', dbPath, key);
    final plain = await File(dbPath).readAsBytes();
    expect(plain.sublist(0, 16), _sqliteHeader().sublist(0, 16));
  });

  test('legacy format decrypts without PPC1 header', () async {
    final plain = _sqliteHeader();
    final aes = AesGcm.with256bits();
    final box = await aes.encrypt(plain, secretKey: SecretKey(key));
    final legacy = Uint8List.fromList([
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);

    final encPath = p.join(tmp.path, 'meta.db.enc');
    final dbPath = p.join(tmp.path, 'meta.db');
    await File(encPath).writeAsBytes(legacy);

    await MetaDbCrypto.decryptDatabaseFile(encPath, dbPath, key);
    final out = await File(dbPath).readAsBytes();
    expect(out.sublist(0, 16), plain.sublist(0, 16));
  });

  test('recoverCrashState prefers newer valid plaintext', () async {
    final dbPath = p.join(tmp.path, 'meta.db');
    final encPath = '${dbPath}.enc';

    final newer = _sqliteHeader()..[20] = 0xAB;
    await File(dbPath).writeAsBytes(newer);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final older = Uint8List.fromList(_sqliteHeader())..[20] = 0xCD;
    final aes = AesGcm.with256bits();
    final box = await aes.encrypt(older, secretKey: SecretKey(key));
    await File(encPath).writeAsBytes([
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);

    await MetaDbCrypto.recoverCrashState(dbPath, encPath, key);
    expect(await File(encPath).exists(), isFalse);
    final kept = await File(dbPath).readAsBytes();
    expect(kept[20], 0xAB);
  });

  test('recoverCrashState uses enc when plaintext corrupt', () async {
    final dbPath = p.join(tmp.path, 'meta.db');
    final encPath = '${dbPath}.enc';

    await File(dbPath).writeAsBytes([1, 2, 3, 4]);

    final good = _sqliteHeader();
    final aes = AesGcm.with256bits();
    final box = await aes.encrypt(good, secretKey: SecretKey(key));
    await File(encPath).writeAsBytes([
      0x50, 0x50, 0x43, 0x31, 1,
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);

    await MetaDbCrypto.recoverCrashState(dbPath, encPath, key);
    expect(await File(encPath).exists(), isFalse);
    final restored = await File(dbPath).readAsBytes();
    expect(restored.sublist(0, 16), good.sublist(0, 16));
  });
}
