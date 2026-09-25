import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

bool get backupFileDownloadSupported => true;

Future<bool> downloadBackupFile(String contents, String filename) async {
  final bytes = Uint8List.fromList(utf8.encode(contents));
  final path = await FilePicker.platform.saveFile(
    dialogTitle: 'Сохранить зашифрованный бэкап',
    fileName: filename,
    type: FileType.custom,
    allowedExtensions: const ['json'],
    bytes: bytes,
  );
  if (path == null) return false;

  // Some desktop implementations return the selected path without writing.
  final file = File(path);
  if (!await file.exists() || await file.length() != bytes.length) {
    await file.writeAsBytes(bytes, flush: true);
  }
  return true;
}
