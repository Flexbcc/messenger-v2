import 'dart:convert';
import 'dart:html' as html;

Future<bool> downloadBackupFile(String contents, String filename) async {
  final bytes = utf8.encode(contents);
  final blob = html.Blob([bytes], 'application/json;charset=utf-8');
  final url = html.Url.createObjectUrlFromBlob(blob);
  try {
    html.AnchorElement(href: url)
      ..download = filename
      ..click();
    return true;
  } finally {
    html.Url.revokeObjectUrl(url);
  }
}

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
