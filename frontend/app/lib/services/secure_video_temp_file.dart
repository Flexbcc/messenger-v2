import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'attachment_file_validation.dart';

const _retention = Duration(hours: 1);
final _random = Random.secure();

Future<String> writeSecureVideoTempFile({
  required Uint8List bytes,
  required String filename,
}) async {
  final validated = validateAttachmentForOpen(
    bytes,
    filename,
    'application/octet-stream',
  );
  final root = await getTemporaryDirectory();
  final directory = Directory('${root.path}/messenger-video-preview');
  await directory.create(recursive: true);
  await _restrictPermissions(directory.path, '700');
  await _purgeExpired(directory);

  final nonce = List<int>.generate(
    16,
    (_) => _random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  final file = File('${directory.path}/$nonce-${validated.filename}');
  if (await file.exists()) {
    throw StateError('temporary video name collision');
  }
  final handle = await file.open(mode: FileMode.write);
  try {
    await handle.writeFrom(bytes);
    await handle.flush();
  } finally {
    await handle.close();
  }
  try {
    await _restrictPermissions(file.path, '600');
  } catch (_) {
    await _deleteBestEffort(file);
    rethrow;
  }
  return file.path;
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
    throw StateError('unable to restrict temporary video permissions');
  }
}

Future<void> _deleteBestEffort(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {}
}
