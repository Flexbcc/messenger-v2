// Главный экран: статус сервера, pairing-код, ключи.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/storage_service.dart';
import 'activity_screen.dart';
import 'format.dart';
import 'pairing_qr.dart';
import 'peers_screen.dart';
import 'settings_screen.dart';

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label скопировано')),
      );
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Личное хранилище'),
        actions: [
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
              MaterialPageRoute(
                builder: (_) => PeersScreen(service: service),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
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
          _InfoCard(
            title: 'Папка',
            value: service.allowedRoot ?? '—',
            monospace: true,
          ),
          const SizedBox(height: 12),
          _InfoCard(
            title: 'Использование',
            value: '${formatBytes(usage.bytes)} · ${usage.files} файлов',
          ),
          const SizedBox(height: 24),
          Text('Сопряжение с нодой', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Сгенерируйте код и введите его на ноде (media-node backend personal_pc). '
            'Код одноразовый, действует 5 минут.',
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
                final json = service.pairingPayloadJson(_addresses);
                if (json != null) _copy('Pairing JSON', json);
              },
              icon: const Icon(Icons.data_object, size: 18),
              label: const Text('Копировать JSON для ноды'),
            ),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            onPressed: service.serverRunning ? service.issuePairingCode : null,
            icon: const Icon(Icons.link),
            label: Text(service.activePairCode == null
                ? 'Сгенерировать код'
                : 'Новый код'),
          ),
          const SizedBox(height: 24),
          Text('Идентификация storage-app', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          _CopyRow(
            label: 'Fingerprint',
            value: service.fingerprint ?? '—',
            onCopy: () => _copy('Fingerprint', service.fingerprint ?? ''),
          ),
          const SizedBox(height: 8),
          _CopyRow(
            label: 'Публичный ключ',
            value: service.storagePubkey ?? '—',
            onCopy: () => _copy('Ключ', service.storagePubkey ?? ''),
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
              Text('Порт: $port', style: theme.textTheme.bodyMedium),
              Text(
                mdnsActive
                    ? 'mDNS: _ouo-ppc._tcp (автообнаружение в LAN)'
                    : 'mDNS: выключен или недоступен',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                relayActive
                    ? 'Relay agent: подключён (NAT fallback)'
                    : 'Relay agent: не подключён (задайте PPC_RELAY_URL)',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                discoveryActive
                    ? 'Discovery: зарегистрирован в каталоге'
                    : 'Discovery: не активен (PPC_DISCOVERY_URL / PPC_STORAGE_NODE_ID)',
                style: theme.textTheme.bodySmall,
              ),
              if (addresses.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'LAN: ${addresses.map((a) => 'http://$a:$port').join(', ')}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.value,
    this.monospace = false,
  });

  final String title;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: Text(title),
        subtitle: Text(
          value,
          style: monospace ? const TextStyle(fontFamily: 'monospace') : null,
        ),
      ),
    );
  }
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
