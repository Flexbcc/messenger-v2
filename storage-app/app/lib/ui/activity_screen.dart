// Журнал операций (audit_log).
library;

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/storage_service.dart';
import 'format.dart';

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key, required this.service});

  final StorageService service;

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  @override
  Widget build(BuildContext context) {
    final entries = widget.service.listAudit();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Журнал операций'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: entries.isEmpty
          ? Center(
              child: Text(
                'Пока нет записей.\nОперации PUT/GET/DELETE/pair/revoke '
                'появятся здесь.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: entries.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) => _AuditTile(entry: entries[i]),
            ),
    );
  }
}

class _AuditTile extends StatelessWidget {
  const _AuditTile({required this.entry});

  final AuditEntry entry;

  Color _resultColor(BuildContext context) {
    if (entry.result == 'ok') return Colors.green.shade700;
    if (entry.result == 'bad_code' ||
        entry.result == 'quota_exceeded' ||
        entry.result == 'integrity') {
      return Theme.of(context).colorScheme.error;
    }
    return Theme.of(context).colorScheme.onSurfaceVariant;
  }

  @override
  Widget build(BuildContext context) {
    final hashShort = entry.hash != null && entry.hash!.length > 12
        ? '${entry.hash!.substring(0, 12)}…'
        : entry.hash;

    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 16,
        child: Text(entry.op.substring(0, 1), style: const TextStyle(fontSize: 12)),
      ),
      title: Text('${entry.op} · ${entry.result}',
          style: TextStyle(color: _resultColor(context))),
      subtitle: Text(
        [
          formatTimestamp(entry.ts),
          if (entry.userUuid != null) 'peer: ${entry.userUuid}',
          if (hashShort != null) 'hash: $hashShort',
          if (entry.size > 0) formatBytes(entry.size),
          if (entry.detail.isNotEmpty) entry.detail,
        ].join(' · '),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
      ),
    );
  }
}
