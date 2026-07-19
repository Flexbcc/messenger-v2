// storage-app — headless-режим ПК-сервера (без UI).
// Запуск:
//   dart run lib/headless_main.dart
//   PPC_ROOT=/Volumes/Storage PPC_PORT=7345 dart run lib/headless_main.dart
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'app.dart';
import 'models/models.dart';

Future<void> main(List<String> args) async {
  final root = Platform.environment['PPC_ROOT'] ??
      p.join(Directory.current.path, '.ppc-data');
  await Directory(root).create(recursive: true);

  final port = int.tryParse(Platform.environment['PPC_PORT'] ?? '') ?? 7345;
  final config = StorageConfig(allowedRoot: root, port: port);

  final app = await StorageApp.bootstrap(config);
  await app.start();

  stdout.writeln('storage-app :: слушаю ${config.host}:${app.server.port}');
  stdout.writeln('storage-app :: allowed_root=$root');
  stdout.writeln('storage-app :: pubkey=${app.keys.publicKeyString}');
  stdout.writeln('storage-app :: fingerprint=${app.keys.fingerprint}');

  final code = app.pairing.issueCode();
  stdout.writeln('storage-app :: pairing-код (TTL 5м): ${code.code}');

  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('storage-app :: остановка…');
    await app.shutdown();
    exit(0);
  });
}
