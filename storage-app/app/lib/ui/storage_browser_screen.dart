import 'package:flutter/material.dart';

import '../services/storage_service.dart';
import 'format.dart';
import 'ouo_components.dart';

class StorageBrowserScreen extends StatefulWidget {
  const StorageBrowserScreen({super.key, required this.service});

  final StorageService service;

  @override
  State<StorageBrowserScreen> createState() => _StorageBrowserScreenState();
}

class _StorageBrowserScreenState extends State<StorageBrowserScreen> {
  @override
  Widget build(BuildContext context) {
    final objects = widget.service.listStoredBlobs();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Содержимое хранилища'),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            onPressed: () => setState(() {}),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: objects.isEmpty
          ? OuoEmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'Здесь пока пусто',
              description: 'Подключите телефон и выберите этот ПК как '
                  'личное хранилище. Здесь будут видны только размер, '
                  'дата и технический ID. Фото и сообщения остаются зашифрованными.',
              actionLabel: 'Вернуться и подключить телефон',
              onAction: () => Navigator.of(context).pop(),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: objects.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final object = objects[index];
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: Text(
                      '${object.hash.substring(0, 12)}…',
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    subtitle: Text(
                      'Устройство: ${object.userUuid}\n'
                      'Последний доступ: ${formatTimestamp(object.lastAccess)}',
                    ),
                    trailing: Text(formatBytes(object.size)),
                    isThreeLine: true,
                  ),
                );
              },
            ),
    );
  }
}
