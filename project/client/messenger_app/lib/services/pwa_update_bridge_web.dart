// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;

/// Listens for Flutter PWA service worker updates and signals when reload is safe.
class PwaUpdateBridge {
  PwaUpdateBridge._();
  static final instance = PwaUpdateBridge._();

  html.ServiceWorkerRegistration? _registration;
  Timer? _poll;
  void Function()? _onReady;

  void start(void Function() onReloadReady) {
    _onReady = onReloadReady;
    final sw = html.window.navigator.serviceWorker;
    if (sw == null) return;

    sw.ready.then((reg) {
      _registration = reg;
      reg.addEventListener('updatefound', (_) => _trackInstalling(reg));
      _poll ??= Timer.periodic(const Duration(minutes: 30), (_) => reg.update());
    });

    // Periodic check even before ready.
    _poll ??= Timer.periodic(const Duration(minutes: 30), (_) {
      sw.getRegistration().then((reg) => reg?.update());
    });
  }

  void _trackInstalling(html.ServiceWorkerRegistration reg) {
    final installing = reg.installing;
    if (installing == null) return;
    installing.addEventListener('statechange', (_) {
      if (installing.state == 'installed' &&
          html.window.navigator.serviceWorker?.controller != null) {
        _onReady?.call();
      }
    });
  }

  Future<void> applyReload() async {
    final waiting = _registration?.waiting;
    if (waiting != null) {
      waiting.postMessage({'action': 'skipWaiting'});
    }
    html.window.location.reload();
  }

  /// Manual check (e.g. from settings).
  Future<void> checkNow() async {
    await _registration?.update();
    final reg = await html.window.navigator.serviceWorker?.getRegistration();
    await reg?.update();
  }
}
