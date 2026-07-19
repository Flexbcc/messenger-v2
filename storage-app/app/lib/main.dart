// storage-app — Flutter desktop UI.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'services/storage_service.dart';
import 'services/tray_controller.dart';
import 'ui/home_screen.dart';
import 'ui/onboarding_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    await initDesktopWindow();
  }
  runApp(const StorageAppEntry());
}

class StorageAppEntry extends StatefulWidget {
  const StorageAppEntry({super.key});

  @override
  State<StorageAppEntry> createState() => _StorageAppEntryState();
}

class _StorageAppEntryState extends State<StorageAppEntry> with WindowListener {
  late final StorageService _service;
  TrayController? _tray;

  @override
  void initState() {
    super.initState();
    _service = StorageService();
    _service.addListener(_onServiceChanged);
    _service.init().then((_) => _maybeInitTray());
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
  }

  void _onServiceChanged() {
    _tray?.syncMenu();
    if (_service.phase == StorageUiPhase.ready && _tray == null) {
      _maybeInitTray();
    }
  }

  Future<void> _maybeInitTray() async {
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) return;
    if (_service.phase != StorageUiPhase.ready || _tray != null) return;
    _tray = TrayController(
      service: _service,
      onQuit: _quitApp,
    );
    await _tray!.init();
  }

  void _quitApp() {
    _service.dispose();
    exit(0);
  }

  @override
  void onWindowClose() async {
    if (_service.settings.minimizeToTray) {
      await _tray?.hideWindow();
    } else {
      _quitApp();
    }
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    _tray?.dispose();
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      windowManager.removeListener(this);
    }
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        return MaterialApp(
          title: 'storage-app',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            useMaterial3: true,
          ),
          home: _buildHome(),
        );
      },
    );
  }

  Widget _buildHome() {
    switch (_service.phase) {
      case StorageUiPhase.loading:
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      case StorageUiPhase.onboarding:
        return OnboardingScreen(service: _service);
      case StorageUiPhase.ready:
        return HomeScreen(service: _service);
      case StorageUiPhase.error:
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 16),
                  Text(
                    _service.errorMessage ?? 'Неизвестная ошибка',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _service.init,
                    child: const Text('Повторить'),
                  ),
                ],
              ),
            ),
          ),
        );
    }
  }
}
