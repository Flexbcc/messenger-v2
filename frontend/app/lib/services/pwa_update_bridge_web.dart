// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

/// Reloads the web application without touching local identity or message data.
///
/// Flutter's offline service worker is intentionally disabled. The only service
/// worker in this app is scoped to `/push/` and must never be used for app
/// updates or unregistered here.
class PwaUpdateBridge {
  PwaUpdateBridge._();
  static final instance = PwaUpdateBridge._();

  Future<void> applyReload() async {
    final current = Uri.parse(html.window.location.href);
    final query = Map<String, String>.from(current.queryParameters)
      ..['__update'] = DateTime.now().millisecondsSinceEpoch.toString();
    html.window.location.replace(
      current.replace(queryParameters: query).toString(),
    );
  }
}
