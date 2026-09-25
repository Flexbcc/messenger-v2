import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'attachment_file_validation.dart';

const _retention = Duration(hours: 1);
final _random = Random.secure();

Future<void> openOrDownloadAttachment(
  Uint8List bytes,
  String filename,
  String mime,
) async {
  final validated = validateAttachmentForOpen(bytes, filename, mime);
  final tempRoot = await getTemporaryDirectory();
  final dir = Directory('${tempRoot.path}/messenger-open-files');
  await dir.create(recursive: true);
  await _restrictPermissions(dir.path, '700');
  await _purgeExpired(dir);

  final nonce = List<int>.generate(
    16,
    (_) => _random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  final path = '${dir.path}/$nonce-${validated.filename}';
  final file = File(path);
  if (await file.exists()) {
    throw StateError('temporary attachment name collision');
  }
  final handle = await file.open(mode: FileMode.write);
  try {
    await handle.writeFrom(bytes);
    await handle.flush();
  } finally {
    await handle.close();
  }
  await _restrictPermissions(path, '600');

  final result = await OpenFilex.open(path);
  if (result.type != ResultType.done) {
    await _deleteBestEffort(file);
    throw StateError('the operating system refused to open the attachment');
  }
  Timer(_retention, () => _deleteBestEffort(file));
}

Future<void> _purgeExpired(Directory directory) async {
  final cutoff = DateTime.now().subtract(_retention);
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File) continue;
    try {
      if ((await entity.lastModified()).isBefore(cutoff)) {
        await entity.delete();
      }
    } catch (_) {}
  }
}

Future<void> _restrictPermissions(String path, String mode) async {
  if (!Platform.isMacOS && !Platform.isLinux) return;
  final result = await Process.run('chmod', [mode, path]);
  if (result.exitCode != 0) {
    throw StateError('unable to restrict temporary attachment permissions');
  }
}

Future<void> _deleteBestEffort(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {}
}
