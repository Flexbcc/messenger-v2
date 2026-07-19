// Системный tray — фоновая работа сервера при закрытом окне.
library;

import 'dart:ui';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'storage_service.dart';

class TrayController with TrayListener {
  TrayController({
    required this.service,
    required this.onQuit,
  });

  final StorageService service;
  final void Function() onQuit;
  bool _ready = false;

  Future<void> init() async {
    await trayManager.setIcon('assets/icons/tray.png');
    await trayManager.setToolTip('storage-app — личное хранилище');
    await _rebuildMenu();
    trayManager.addListener(this);
    _ready = true;
  }

  Future<void> _rebuildMenu() async {
    final running = service.serverRunning;
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Показать окно'),
          MenuItem(
            key: 'toggle',
            label: running ? 'Остановить сервер' : 'Запустить сервер',
          ),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Выход'),
        ],
      ),
    );
  }

  Future<void> syncMenu() async {
    if (!_ready) return;
    await _rebuildMenu();
  }

  Future<void> showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> hideWindow() async {
    await windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() {
    showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        showWindow();
      case 'toggle':
        service.toggleServer().then((_) => syncMenu());
      case 'quit':
        onQuit();
    }
  }

  void dispose() {
    trayManager.removeListener(this);
  }
}

/// Инициализация window_manager для desktop.
Future<void> initDesktopWindow() async {
  await windowManager.ensureInitialized();
  const opts = WindowOptions(
    size: Size(520, 720),
    minimumSize: Size(420, 560),
    center: true,
    title: 'storage-app',
  );
  await windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
