import 'dart:typed_data';

import 'attachment_file_validation.dart';

Future<void> openOrDownloadAttachment(
  Uint8List bytes,
  String filename,
  String mime,
) async {
  validateAttachmentForOpen(bytes, filename, mime);
  throw UnsupportedError(
    'Opening or downloading attachments is not supported on this target',
  );
}
