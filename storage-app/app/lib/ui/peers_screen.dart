// Список сопряжённых пиров (нод / телефонов) + revoke.
library;

import 'package:flutter/material.dart';

import '../services/storage_service.dart';
import 'format.dart';
import 'ouo_components.dart';

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
        title: const Text('Подключённые устройства'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: peers.isEmpty
          ? OuoEmptyState(
              icon: Icons.phonelink_lock_outlined,
              title: 'Нет подключённых устройств',
              description: 'Вернитесь на главный экран, нажмите '
                  '«Подключить телефон» и отсканируйте QR в OUO Messenger.',
              actionLabel: 'Подключить телефон',
              onAction: () => Navigator.of(context).pop(),
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
                        Text(
                          'ID: ${peer.userUuid}',
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
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
                      tooltip: 'Отключить устройство',
                      icon: Icon(
                        Icons.link_off,
                        color: Theme.of(context).colorScheme.error,
                      ),
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
          title: const Text('Отключить устройство?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Устройство «${name.isNotEmpty ? name : userUuid}» '
                'потеряет доступ.',
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Удалить зашифрованные объекты устройства'),
                subtitle: const Text(
                  'Действие необратимо. Данные других устройств останутся '
                  'без изменений.',
                ),
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
