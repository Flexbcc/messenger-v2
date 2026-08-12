import 'dart:io';
import 'dart:typed_data';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

Future<String?> openOrDownloadAttachment(
  Uint8List bytes,
  String filename,
  String mime,
) async {
  final dir = await getTemporaryDirectory();
  final safeName = filename.replaceAll(RegExp(r'[^\w.\-]'), '_');
  final path = '${dir.path}/chat_$safeName';
  final file = File(path);
  if (!await file.exists() || await file.length() != bytes.length) {
    await file.writeAsBytes(bytes, flush: true);
  }
  final result = await OpenFilex.open(path);
  return result.type == ResultType.done ? null : path;
}
