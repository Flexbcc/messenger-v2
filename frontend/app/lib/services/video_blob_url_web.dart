// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

/// Creates a temporary object URL for [bytes] so [VideoPlayerController.networkUrl]
/// can play in-memory video data in web/PWA.
String? createVideoBlobUrl(List<int> bytes, String mime) {
  final blob = html.Blob([bytes], mime);
  return html.Url.createObjectUrl(blob);
}

/// Frees the object URL created by [createVideoBlobUrl].
void revokeVideoBlobUrl(String url) {
  html.Url.revokeObjectUrl(url);
}

// ignore_for_file: deprecated_member_use
