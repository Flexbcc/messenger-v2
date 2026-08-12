// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:typed_data';

Future<String?> openOrDownloadAttachment(
  Uint8List bytes,
  String filename,
  String mime,
) async {
  final blob = html.Blob([bytes], mime);
  final url = html.Url.createObjectUrlFromBlob(blob);
  try {
    html.AnchorElement(href: url)
      ..download = filename
      ..click();
    return null;
  } finally {
    html.Url.revokeObjectUrl(url);
  }
}
