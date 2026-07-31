import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../calls/call_signal.dart';
import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_empty_state.dart';
import '../core/ui/app_segmented_control.dart';
import '../core/ui/app_avatar.dart';
import '../models/call_history_entry.dart';
import '../state/app_controller.dart';
import '../utils/format.dart';
import 'contact_profile_screen.dart';

class CallsScreen extends ConsumerStatefulWidget {
  const CallsScreen({super.key});

  @override
  ConsumerState<CallsScreen> createState() => _CallsScreenState();
}

class _CallsScreenState extends ConsumerState<CallsScreen> {
  bool _missedOnly = false;

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final calls = _missedOnly
        ? controller.callHistory.where((c) => c.missed).toList()
        : controller.callHistory;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Звонки'),
        actions: [
          if (controller.callHistory.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmClearHistory(context),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenPadding,
              AppSpacing.md,
              AppSpacing.screenPadding,
              AppSpacing.sm,
            ),
            child: AppSegmentedControl(
              selectedIndex: _missedOnly ? 1 : 0,
              labels: const ['Все', 'Пропущенные'],
              onChanged: (i) => setState(() => _missedOnly = i == 1),
            ),
          ),
          Expanded(
            child: calls.isEmpty
                ? AppEmptyState(
                    icon: _missedOnly ? Icons.phone_missed_outlined : Icons.call_outlined,
                    title: _missedOnly ? 'Нет пропущенных звонков' : 'История звонков пуста',
                    subtitle: _missedOnly ? null : 'Звонки появятся после аудио- или видеовызова',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                    itemCount: calls.length,
                    itemBuilder: (context, i) => _CallRow(entry: calls[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearHistory(BuildContext context) async {
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Очистить историю звонков?'),
        content: const Text('Журнал будет удалён только на этом устройстве.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Очистить', style: TextStyle(color: colors.danger)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(appControllerProvider).clearCallHistory();
    }
  }
}

class _CallRow extends ConsumerWidget {
  const _CallRow({required this.entry});
  final CallHistoryEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final text = context.textStyles;
    final controller = ref.read(appControllerProvider);
    final name = controller.labelFor(entry.peerUserId);
    final missed = entry.missed;
    final color = missed ? colors.danger : colors.textSecondary;
    final directionIcon = entry.outgoing ? Icons.call_made : Icons.call_received;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ContactProfileScreen(userId: entry.peerUserId, displayName: name)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding, vertical: 10),
          child: Row(
            children: [
              AppAvatar(label: name),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: text.body.copyWith(color: missed ? colors.danger : colors.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(directionIcon, size: 14, color: color),
                        if (entry.kind == CallKind.video) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.videocam_outlined, size: 14, color: color),
                        ],
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            '${_statusLabel(entry)} · ${formatCallHistoryTime(entry.startedAt)}',
                            style: text.caption.copyWith(color: color),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: controller.currentCall != null
                    ? null
                    : () async {
                        try {
                          await controller.callPeer(peerUserId: entry.peerUserId, kind: entry.kind);
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
                          }
                        }
                      },
                icon: Icon(
                  entry.kind == CallKind.video ? Icons.videocam_outlined : Icons.call_outlined,
                  color: colors.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _statusLabel(CallHistoryEntry entry) => switch (entry.status) {
        CallHistoryStatus.completed =>
          entry.durationSeconds != null ? _formatDuration(entry.durationSeconds!) : 'Разговор',
        CallHistoryStatus.missed => 'Пропущенный',
        CallHistoryStatus.cancelled => 'Отменён',
        CallHistoryStatus.rejected => entry.outgoing ? 'Не ответил' : 'Отклонён',
        CallHistoryStatus.busy => 'Занято',
        CallHistoryStatus.failed => 'Сбой',
      };

  String _formatDuration(int seconds) {
    if (seconds < 60) return '$seconds сек';
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
