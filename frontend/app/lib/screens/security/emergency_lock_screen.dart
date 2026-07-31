import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_button.dart';
import '../../core/ui/app_card.dart';
import '../../models/emergency_lock_level.dart';
import '../../state/app_controller.dart';

/// Emergency Lock — three severity levels (roadmap §4).
class EmergencyLockScreen extends ConsumerWidget {
  const EmergencyLockScreen({super.key});

  Future<void> _confirm(BuildContext context, WidgetRef ref, EmergencyLockLevel level) async {
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${level.label} блокировка'),
        content: Text(
          '${level.description}\n\nПродолжить? Это действие нельзя отменить.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Заблокировать',
              style: TextStyle(color: level == EmergencyLockLevel.critical ? colors.danger : colors.warning),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await ref.read(appControllerProvider).executeEmergencyLock(level);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Экстренная блокировка: ${level.label}')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final text = context.textStyles;

    return Scaffold(
      appBar: AppBar(title: const Text('Экстренная блокировка')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        children: [
          AppCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, color: colors.warning, size: 28),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('При потере устройства', style: text.subtitle),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'Мгновенно завершите сеансы и защитите аккаунт. Выберите уровень по ситуации.',
                        style: text.caption,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          _LevelCard(
            level: EmergencyLockLevel.soft,
            icon: Icons.logout,
            color: colors.primary,
            onActivate: () => _confirm(context, ref, EmergencyLockLevel.soft),
          ),
          const SizedBox(height: AppSpacing.md),
          _LevelCard(
            level: EmergencyLockLevel.full,
            icon: Icons.phonelink_erase,
            color: colors.warning,
            onActivate: () => _confirm(context, ref, EmergencyLockLevel.full),
          ),
          const SizedBox(height: AppSpacing.md),
          _LevelCard(
            level: EmergencyLockLevel.critical,
            icon: Icons.delete_forever_outlined,
            color: colors.danger,
            onActivate: () => _confirm(context, ref, EmergencyLockLevel.critical),
          ),
        ],
      ),
    );
  }
}

class _LevelCard extends StatelessWidget {
  const _LevelCard({
    required this.level,
    required this.icon,
    required this.color,
    required this.onActivate,
  });

  final EmergencyLockLevel level;
  final IconData icon;
  final Color color;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: AppSpacing.sm),
              Text(level.label, style: text.sectionTitle),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(level.description, style: text.caption),
          const SizedBox(height: AppSpacing.md),
          AppButton(
            label: 'Активировать',
            variant: level == EmergencyLockLevel.critical ? AppButtonVariant.danger : AppButtonVariant.secondary,
            onPressed: onActivate,
          ),
        ],
      ),
    );
  }
}
