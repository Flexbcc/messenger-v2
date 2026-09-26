// Главный экран: статус сервера, pairing-код, ключи.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/storage_service.dart';
import 'activity_screen.dart';
import 'format.dart';
import 'ouo_components.dart';
import 'pairing_qr.dart';
import 'peers_screen.dart';
import 'settings_screen.dart';
import 'storage_browser_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.service});

  final StorageService service;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Timer? _tick;
  List<String> _addresses = [];

  @override
  void initState() {
    super.initState();
    _loadAddresses();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      widget.service.clearExpiredPairCode();
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadAddresses() async {
    final addrs = await widget.service.localAddresses();
    if (mounted) setState(() => _addresses = addrs);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$label скопировано')));
    }
  }

  int _pairTtlRemaining() {
    final code = widget.service.activePairCode;
    if (code == null) return 0;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return (code.expiresAt - now).clamp(0, 300);
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final theme = Theme.of(context);
    final usage = service.globalUsage();
    final port = service.listenPort;
    final pending = service.pendingPairRequests;
    final peers = service.listPeers();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Личное хранилище'),
        actions: [
          IconButton(
            tooltip: 'Содержимое хранилища',
            icon: const Icon(Icons.inventory_2_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => StorageBrowserScreen(service: service),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Журнал операций',
            icon: const Icon(Icons.receipt_long),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ActivityScreen(service: service),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Настройки',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(service: service),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Сопряжённые пиры',
            icon: const Icon(Icons.devices),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => PeersScreen(service: service)),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: [
          OuoPageIntro(
            icon: peers.isEmpty
                ? Icons.rocket_launch_outlined
                : Icons.shield_outlined,
            title: peers.isEmpty ? 'Закончим настройку' : 'Хранилище готово',
            description: peers.isEmpty
                ? 'Папка выбрана и сервер работает. Осталось подключить телефон.'
                : 'Ваши устройства могут хранить здесь E2EE-файлы. Этот ПК не знает их содержимое.',
          ),
          const SizedBox(height: 16),
          _SetupProgress(
            folderReady: service.allowedRoot?.isNotEmpty == true,
            serverReady: service.serverRunning,
            phoneReady: peers.isNotEmpty,
            onConnect: service.serverRunning ? service.issuePairingCode : null,
          ),
          const SizedBox(height: 16),
          _StatusCard(
            running: service.serverRunning,
            port: port,
            addresses: _addresses,
            mdnsActive: service.mdnsActive,
            relayActive: service.relayActive,
            discoveryActive: service.discoveryActive,
            onToggle: service.toggleServer,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                  child: _QuickAction(
                      icon: Icons.devices_outlined,
                      label: 'Устройства',
                      value: '${peers.length}',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => PeersScreen(service: service))))),
              const SizedBox(width: 12),
              Expanded(
                  child: _QuickAction(
                      icon: Icons.inventory_2_outlined,
                      label: 'Хранилище',
                      value: '${formatBytes(usage.bytes)} · ${usage.files}',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) =>
                              StorageBrowserScreen(service: service))))),
              const SizedBox(width: 12),
              Expanded(
                  child: _QuickAction(
                      icon: Icons.receipt_long_outlined,
                      label: 'События',
                      value: 'Журнал',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => ActivityScreen(service: service))))),
            ],
          ),
          const SizedBox(height: 24),
          if (pending.isNotEmpty) ...[
            Text('Запросы доступа', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            ...pending.map(
              (request) => Card(
                color: theme.colorScheme.tertiaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.phonelink_lock),
                  title: Text(
                      request.name.isEmpty ? request.nodeId : request.name),
                  subtitle: Text(
                    'Телефон просит доступ к хранилищу. '
                    'Разрешайте только если запрос сейчас инициировали вы.\n'
                    'ID: ${request.nodeId}',
                  ),
                  isThreeLine: true,
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      IconButton(
                        tooltip: 'Отклонить',
                        onPressed: () => service.denyPairRequest(request.id),
                        icon: const Icon(Icons.close),
                      ),
                      FilledButton(
                        onPressed: () => service.approvePairRequest(request.id),
                        child: const Text('Разрешить'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
          Text(
              peers.isEmpty
                  ? 'Шаг 3 из 3 · Подключите телефон'
                  : 'Добавить ещё одно устройство',
              style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Откройте OUO Messenger → Настройки → Личное хранилище. '
            'Нажмите «Сканировать QR». Код одноразовый и живёт 5 минут.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          if (service.activePairCode != null) ...[
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Text(
                    service.activePairCode!.code,
                    style: theme.textTheme.displayMedium?.copyWith(
                      letterSpacing: 8,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'осталось ${_pairTtlRemaining()} с',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            PairingQrCard(service: service, lanHosts: _addresses),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                final json = service.pairingPayloadJson(
                  _addresses,
                  includeQrSecret: false,
                );
                if (json != null) _copy('Pairing JSON', json);
              },
              icon: const Icon(Icons.data_object, size: 18),
              label: const Text('Ручное подключение без QR'),
            ),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            onPressed: service.serverRunning ? service.issuePairingCode : null,
            icon: const Icon(Icons.link),
            label: Text(
              service.activePairCode == null
                  ? 'Подключить телефон'
                  : 'Новый код',
            ),
          ),
          const SizedBox(height: 24),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Технические сведения'),
            subtitle:
                const Text('Адреса, папка и ключи — обычно открывать не нужно'),
            children: [
              _CopyRow(
                  label: 'Папка',
                  value: service.allowedRoot ?? '—',
                  onCopy: () => _copy('Папка', service.allowedRoot ?? '')),
              _CopyRow(
                  label: 'Fingerprint',
                  value: service.fingerprint ?? '—',
                  onCopy: () =>
                      _copy('Fingerprint', service.fingerprint ?? '')),
              _CopyRow(
                  label: 'Публичный ключ',
                  value: service.storagePubkey ?? '—',
                  onCopy: () => _copy('Ключ', service.storagePubkey ?? '')),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.running,
    required this.port,
    required this.addresses,
    required this.mdnsActive,
    required this.relayActive,
    required this.discoveryActive,
    required this.onToggle,
  });

  final bool running;
  final int port;
  final List<String> addresses;
  final bool mdnsActive;
  final bool relayActive;
  final bool discoveryActive;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = running ? Colors.green : theme.colorScheme.outline;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 12, color: color),
                const SizedBox(width: 8),
                Text(
                  running ? 'Сервер запущен' : 'Сервер остановлен',
                  style: theme.textTheme.titleMedium,
                ),
                const Spacer(),
                Switch(value: running, onChanged: (_) => onToggle()),
              ],
            ),
            if (running) ...[
              const SizedBox(height: 8),
              Text(
                mdnsActive
                    ? 'Телефон сможет найти хранилище в вашей домашней сети.'
                    : 'Сервер работает, но автопоиск в домашней сети недоступен.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Text(
                  relayActive
                      ? 'Удалённый доступ тоже готов.'
                      : 'Сейчас доступно в локальной сети.',
                  style: theme.textTheme.bodySmall),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Диагностика'),
                childrenPadding: const EdgeInsets.only(bottom: 8),
                children: [
                  Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                          'Порт: $port\nmDNS: ${mdnsActive ? 'активен' : 'недоступен'}\nRelay: ${relayActive ? 'подключён' : 'не настроен'}\nDiscovery: ${discoveryActive ? 'зарегистрирован' : 'не настроен'}${addresses.isEmpty ? '' : '\nLAN: ${addresses.map((a) => 'http://$a:$port').join(', ')}'}',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(fontFamily: 'monospace'))),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SetupProgress extends StatelessWidget {
  const _SetupProgress(
      {required this.folderReady,
      required this.serverReady,
      required this.phoneReady,
      required this.onConnect});
  final bool folderReady;
  final bool serverReady;
  final bool phoneReady;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    final done =
        [folderReady, serverReady, phoneReady].where((value) => value).length;
    return OuoSectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Настройка', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          Text('$done / 3', style: Theme.of(context).textTheme.bodyMedium)
        ]),
        const SizedBox(height: 12),
        LinearProgressIndicator(
            value: done / 3,
            minHeight: 6,
            borderRadius: BorderRadius.circular(8)),
        const SizedBox(height: 16),
        _SetupLine(done: folderReady, text: 'Папка для шифротекста выбрана'),
        _SetupLine(done: serverReady, text: 'Хранилище запущено'),
        _SetupLine(
            done: phoneReady,
            text: phoneReady ? 'Телефон подключён' : 'Подключите телефон'),
        if (!phoneReady) ...[
          const SizedBox(height: 12),
          FilledButton.icon(
              onPressed: onConnect,
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Показать QR для телефона')),
        ],
      ]),
    );
  }
}

class _SetupLine extends StatelessWidget {
  const _SetupLine({required this.done, required this.text});
  final bool done;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Icon(done ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 20,
              color: done
                  ? Colors.green
                  : Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Text(text)
        ]),
      );
}

class _QuickAction extends StatelessWidget {
  const _QuickAction(
      {required this.icon,
      required this.label,
      required this.value,
      required this.onTap});
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                Icon(icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(label,
                          style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 3),
                      Text(value, style: Theme.of(context).textTheme.bodySmall)
                    ])),
                const Icon(Icons.chevron_right)
              ])),
        ),
      );
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({
    required this.label,
    required this.value,
    required this.onCopy,
  });

  final String label;
  final String value;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 2),
              SelectableText(
                value,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Копировать',
          icon: const Icon(Icons.copy, size: 18),
          onPressed: onCopy,
        ),
      ],
    );
  }
}
