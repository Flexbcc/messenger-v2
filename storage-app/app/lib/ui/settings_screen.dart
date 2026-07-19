// Настройки: папка, порт, поведение tray.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/storage_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.service});

  final StorageService service;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _portCtrl;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _portCtrl = TextEditingController(
      text: '${widget.service.settings.port}',
    );
  }

  @override
  void dispose() {
    _portCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Новая папка хранения',
    );
    if (path == null) return;
    final ok = await _confirm(
      'Сменить папку?',
      'Сервер перезапустится с новой папкой.\n'
      'Данные в старой папке останутся на диске.',
    );
    if (!ok) return;
    await _run(() => widget.service.updateStoragePath(path));
  }

  Future<void> _savePort() async {
    final port = int.tryParse(_portCtrl.text.trim());
    if (port == null || port < 1024 || port > 65535) {
      _snack('Порт должен быть 1024–65535');
      return;
    }
    if (port == widget.service.listenPort) return;
    await _run(() => widget.service.updatePort(port));
    _snack('Порт обновлён: $port');
  }

  Future<void> _resetOnboarding() async {
    final ok = await _confirm(
      'Сбросить настройки?',
      'Вернётся экран онбординга. Файлы на диске не удаляются.',
    );
    if (!ok || !mounted) return;
    await widget.service.resetOnboarding();
  }

  Future<void> _run(Future<void> Function() fn) async {
    setState(() => _busy = true);
    try {
      await fn();
    } catch (e) {
      if (mounted) _snack('Ошибка: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.service;

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Хранение', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Папка'),
              subtitle: Text(
                s.allowedRoot ?? '—',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              trailing: OutlinedButton(
                onPressed: _pickFolder,
                child: const Text('Сменить'),
              ),
            ),
            const Divider(height: 32),
            Text('Сеть', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _portCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Порт HTTP',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _savePort,
                  child: const Text('Применить'),
                ),
              ],
            ),
            const Divider(height: 32),
            Text('Приложение', style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Сворачивать в tray при закрытии'),
              subtitle: const Text('Сервер продолжит работу в фоне'),
              value: s.settings.minimizeToTray,
              onChanged: (v) => s.setMinimizeToTray(v),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _resetOnboarding,
              icon: const Icon(Icons.restart_alt),
              label: const Text('Сбросить онбординг'),
            ),
            if (_busy) ...[
              const SizedBox(height: 24),
              const Center(child: CircularProgressIndicator()),
            ],
          ],
        ),
      ),
    );
  }
}
