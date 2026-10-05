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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.service.showPairingOnReady && mounted) {
        widget.service.showPairingOnReady = false;
        _showPairingDialog();
      }
    });
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

  Future<void> _showPairingDialog() async {
    if (!widget.service.serverRunning) return;
    widget.service.issuePairingCode();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _PairingDialog(
        service: widget.service,
        lanHosts: _addresses,
        onCopyManualCode: (json) => _copy('Код подключения', json),
      ),
    );
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
            onConnect: service.serverRunning ? _showPairingDialog : null,
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
          FilledButton.icon(
            onPressed: service.serverRunning ? _showPairingDialog : null,
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

class _PairingDialog extends StatefulWidget {
  const _PairingDialog({
    required this.service,
    required this.lanHosts,
    required this.onCopyManualCode,
  });

  final StorageService service;
  final List<String> lanHosts;
  final ValueChanged<String> onCopyManualCode;

  @override
  State<_PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<_PairingDialog> {
  Timer? _poll;
  late final int _initialPeerCount;

  @override
  void initState() {
    super.initState();
    _initialPeerCount = widget.service.listPeers().length;
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      if (widget.service.listPeers().length > _initialPeerCount) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.service.pendingPairRequests;
    final request = pending.isEmpty ? null : pending.first;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: request != null
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    const Icon(Icons.phonelink_lock),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Подтвердите подключение',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  Text(
                    '${request.name.isEmpty ? 'Новое устройство' : request.name} '
                    'просит доступ к этому хранилищу. Разрешайте только запрос, '
                    'который вы только что начали в OUO Messenger.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'ID: ${request.nodeId}',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          widget.service.denyPairRequest(request.id);
                          Navigator.of(context).pop();
                        },
                        child: const Text('Отклонить'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () {
                          widget.service.approvePairRequest(request.id);
                          setState(() {});
                        },
                        icon: const Icon(Icons.check),
                        label: const Text('Разрешить'),
                      ),
                    ),
                  ]),
                ])
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    const Icon(Icons.qr_code_2),
                    const SizedBox(width: 10),
                    Text('Подключить телефон',
                        style: Theme.of(context).textTheme.titleLarge),
                    const Spacer(),
                    IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close)),
                  ]),
                  const SizedBox(height: 8),
                  const Text(
                    'В OUO Messenger откройте «Настройки → Личное '
                    'хранилище» и отсканируйте код.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  PairingQrCard(
                    service: widget.service,
                    lanHosts: widget.lanHosts,
                  ),
                  const SizedBox(height: 12),
                  Text('Код одноразовый и действует 5 минут.',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () {
                      final json = widget.service.pairingPayloadJson(
                        widget.lanHosts,
                        includeQrSecret: false,
                      );
                      if (json != null) widget.onCopyManualCode(json);
                    },
                    icon: const Icon(Icons.keyboard_outlined),
                    label: const Text('Скопировать ручной код'),
                  ),
                ]),
        ),
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
