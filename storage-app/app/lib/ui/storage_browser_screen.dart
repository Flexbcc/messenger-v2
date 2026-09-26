import 'package:flutter/material.dart';

import '../models/models.dart';
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
    final groups = <String, List<StoredBlobMetadata>>{};
    for (final object in objects) {
      final created = DateTime.fromMillisecondsSinceEpoch(
        object.createdAt * 1000,
      ).toLocal();
      groups.putIfAbsent(_dateLabel(created), () => []).add(object);
    }
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
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: groups.length,
              itemBuilder: (context, index) {
                final group = groups.entries.elementAt(index);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                        child: Text(
                          group.key,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      ...group.value.map(
                        (object) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Card(
                            child: ListTile(
                              leading: const Icon(Icons.lock_outline),
                              title: Text(
                                '${object.hash.substring(0, 12)}…',
                                style: const TextStyle(fontFamily: 'monospace'),
                              ),
                              subtitle: Text(
                                'Зашифрованный объект · устройство ${object.userUuid}\n'
                                'Последний доступ: ${formatTimestamp(object.lastAccess)}',
                              ),
                              trailing: Text(formatBytes(object.size)),
                              isThreeLine: true,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  String _dateLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final difference = today.difference(day).inDays;
    if (difference == 0) return 'Сегодня';
    if (difference == 1) return 'Вчера';
    const months = <String>[
      'января',
      'февраля',
      'марта',
      'апреля',
      'мая',
      'июня',
      'июля',
      'августа',
      'сентября',
      'октября',
      'ноября',
      'декабря',
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }
}
