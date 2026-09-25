// Список сопряжённых пиров (нод / телефонов) + revoke.
library;

import 'package:flutter/material.dart';

import '../services/storage_service.dart';
import 'format.dart';

class PeersScreen extends StatefulWidget {
  const PeersScreen({super.key, required this.service});

  final StorageService service;

  @override
  State<PeersScreen> createState() => _PeersScreenState();
}

class _PeersScreenState extends State<PeersScreen> {
  @override
  Widget build(BuildContext context) {
    final peers = widget.service.listPeers();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Сопряжённые пиры'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: peers.isEmpty
          ? Center(
              child: Text(
                'Пока нет сопряжённых пиров.\n'
                'Сгенерируйте код на главном экране и выполните pairing на ноде.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: peers.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final peer = peers[i];
                final usage = widget.service.peerUsage(peer.userUuid);
                final last = widget.service.peerLastAccess(peer.userUuid);
                return Card(
                  child: ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.hub)),
                    title: Text(
                      peer.name.isNotEmpty ? peer.name : peer.userUuid,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('ID: ${peer.userUuid}',
                            style: const TextStyle(fontFamily: 'monospace')),
                        Text('Ключ: ${peerFingerprint(peer.pubkey)}'),
                        Text('Добавлен: ${formatTimestamp(peer.addedAt)}'),
                        if (last != null)
                          Text('Активность: ${formatTimestamp(last)}'),
                        Text(
                          '${formatBytes(usage.bytes)} · ${usage.files} файлов',
                        ),
                      ],
                    ),
                    isThreeLine: true,
                    trailing: IconButton(
                      tooltip: 'Отозвать pairing',
                      icon: Icon(Icons.link_off,
                          color: Theme.of(context).colorScheme.error),
                      onPressed: () => _revoke(peer.userUuid, peer.name),
                    ),
                  ),
                );
              },
            ),
    );
  }

  Future<void> _revoke(String userUuid, String name) async {
    var deleteBlobs = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Отозвать pairing?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Пир «${name.isNotEmpty ? name : userUuid}» потеряет доступ.'),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Удалить блобы этого пира'),
                subtitle: const Text('Папка users/<id>/ на диске'),
                value: deleteBlobs,
                onChanged: (v) => setLocal(() => deleteBlobs = v ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Отозвать'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await widget.service.revokePeer(userUuid, deleteBlobs: deleteBlobs);
    if (mounted) setState(() {});
  }
}
