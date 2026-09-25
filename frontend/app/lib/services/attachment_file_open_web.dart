// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:typed_data';

import 'attachment_file_validation.dart';

Future<void> openOrDownloadAttachment(
  Uint8List bytes,
  String filename,
  String mime,
) async {
  final validated = validateAttachmentForOpen(bytes, filename, mime);
  final blob = html.Blob([bytes], validated.mime);
  final url = html.Url.createObjectUrlFromBlob(blob);
  try {
    html.AnchorElement(href: url)
      ..download = validated.filename
      ..click();
  } finally {
    html.Url.revokeObjectUrl(url);
  }
}
