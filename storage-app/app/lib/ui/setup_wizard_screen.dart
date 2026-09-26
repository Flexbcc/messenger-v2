import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/storage_service.dart';

class SetupWizardScreen extends StatefulWidget {
  const SetupWizardScreen({super.key, required this.service});
  final StorageService service;
  @override
  State<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends State<SetupWizardScreen> {
  final _pages = PageController();
  String? _path;
  int _step = 0;
  bool _localOnly = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.service.defaultStoragePath().then((value) {
      if (mounted) setState(() => _path = value);
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _move(int delta) {
    setState(() => _step += delta);
    _pages.animateToPage(_step,
        duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
  }

  Future<void> _pick() async {
    final value = await FilePicker.getDirectoryPath(
        dialogTitle: 'Выберите папку для OUO');
    if (value != null && mounted) setState(() => _path = value);
  }

  Future<void> _finish() async {
    if (_path == null) return;
    setState(() => _busy = true);
    await widget.service.completeOnboarding(_path!, localOnly: _localOnly);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 24, 32, 8),
              child: Row(children: [
                const Icon(Icons.shield_outlined),
                const SizedBox(width: 10),
                Text('OUO Storage',
                    style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                Text('Шаг ${_step + 1} из 4')
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
              child: LinearProgressIndicator(
                  value: (_step + 1) / 4,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(8)),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _WizardPage(
                    icon: Icons.lock_outline,
                    title: 'Ваше личное хранилище',
                    text: 'Компьютер будет хранить только шифротекст. '
                        'Открыть фото, видео или сообщение в Finder нельзя: '
                        'ключ расшифровки остаётся на телефоне.',
                    child: const _FeatureList(items: [
                      ('Файлы не читает сервер', Icons.visibility_off_outlined),
                      (
                        'Каждое устройство имеет свою область',
                        Icons.people_outline
                      ),
                    ]),
                  ),
                  _WizardPage(
                    icon: Icons.folder_outlined,
                    title: 'Где хранить данные?',
                    text: 'Выберите локальный SSD. iCloud, Dropbox и OneDrive '
                        'лучше не использовать: они могут мешать атомарной записи.',
                    child: Card(
                      child: ListTile(
                        leading: const Icon(Icons.folder_open),
                        title: const Text('Папка хранилища'),
                        subtitle: Text(_path ?? 'Определяем…'),
                        trailing: OutlinedButton(
                            onPressed: _pick, child: const Text('Изменить')),
                      ),
                    ),
                  ),
                  _WizardPage(
                    icon: Icons.lan_outlined,
                    title: 'Как подключаться?',
                    text:
                        'В одной Wi‑Fi/LAN сети телефон находит ПК как AirDrop '
                        'и передаёт данные напрямую. Relay нужен для доступа вне дома.',
                    child: Column(children: [
                      _ChoiceCard(
                          selected: _localOnly,
                          icon: Icons.home_outlined,
                          title: 'Только локальная сеть',
                          subtitle:
                              'Быстро и без внешнего адреса. Рекомендуется.',
                          onTap: () => setState(() => _localOnly = true)),
                      const SizedBox(height: 10),
                      _ChoiceCard(
                          selected: !_localOnly,
                          icon: Icons.public,
                          title: 'LAN + Relay',
                          subtitle:
                              'Вне дома — Relay; дома — быстрое прямое соединение.',
                          onTap: () => setState(() => _localOnly = false)),
                    ]),
                  ),
                  const _WizardPage(
                    icon: Icons.qr_code_2,
                    title: 'Добавим первый телефон',
                    text:
                        'После запуска QR появится по центру. В OUO Messenger '
                        'откройте: Настройки → Личное хранилище → Сканировать QR. '
                        'PIN можно добавить позже как резервный менее безопасный вариант.',
                    child: _FeatureList(items: [
                      (
                        'QR — одноразовый секрет на 5 минут',
                        Icons.verified_user_outlined
                      ),
                      (
                        'Новое ручное подключение просит разрешение на ПК',
                        Icons.phonelink_lock
                      ),
                    ]),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(32),
              child: Row(children: [
                if (_step > 0)
                  TextButton.icon(
                      onPressed: _busy ? null : () => _move(-1),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Назад')),
                const Spacer(),
                FilledButton.icon(
                  onPressed:
                      _busy ? null : (_step == 3 ? _finish : () => _move(1)),
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(
                          _step == 3 ? Icons.qr_code_2 : Icons.arrow_forward),
                  label: Text(_step == 3
                      ? 'Запустить и показать QR'
                      : (_step == 0 ? 'Начать' : 'Продолжить')),
                ),
              ]),
            )
          ]),
        ),
      );
}

class _WizardPage extends StatelessWidget {
  const _WizardPage(
      {required this.icon,
      required this.title,
      required this.text,
      required this.child});
  final IconData icon;
  final String title;
  final String text;
  final Widget child;
  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(32),
              children: [
                Icon(icon,
                    size: 52, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 16),
                Text(title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 10),
                Text(text,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge),
                const SizedBox(height: 24),
                child,
              ]),
        ),
      );
}

class _FeatureList extends StatelessWidget {
  const _FeatureList({required this.items});
  final List<(String, IconData)> items;
  @override
  Widget build(BuildContext context) => Card(
        child: Column(
          children: items
              .map((item) => ListTile(
                  leading: Icon(item.$2,
                      color: Theme.of(context).colorScheme.primary),
                  title: Text(item.$1)))
              .toList(),
        ),
      );
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard(
      {required this.selected,
      required this.icon,
      required this.title,
      required this.subtitle,
      required this.onTap});
  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: ListTile(
            leading: Icon(icon,
                color: selected ? Theme.of(context).colorScheme.primary : null),
            title: Text(title),
            subtitle: Text(subtitle),
            trailing: Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: selected ? Theme.of(context).colorScheme.primary : null),
          ),
        ),
      );
}
