import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_button.dart';
import '../../core/ui/app_card.dart';
import '../../services/emergency_lock_service.dart';
import '../../state/app_controller.dart';

/// Recovery key placeholder — also clears emergency recovery lock (dev/MVP).
class RecoveryKeyScreen extends ConsumerStatefulWidget {
  const RecoveryKeyScreen({super.key});

  @override
  ConsumerState<RecoveryKeyScreen> createState() => _RecoveryKeyScreenState();
}

class _RecoveryKeyScreenState extends ConsumerState<RecoveryKeyScreen> {
  bool _recoveryLock = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final locked = await EmergencyLockService.instance.isRecoveryLockActive();
    if (mounted) setState(() => _recoveryLock = locked);
  }

  Future<void> _clearRecoveryLock() async {
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Снять блокировку?'),
        content: const Text(
          'Используйте только если вы подтвердили безопасность аккаунта. '
          'В продакшене здесь будет проверка ключа восстановления.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Снять', style: TextStyle(color: colors.primary)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await ref.read(appControllerProvider).clearEmergencyRecoveryLock();
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Блокировка восстановления снята')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return Scaffold(
      appBar: AppBar(title: const Text('Ключ восстановления')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_recoveryLock)
              AppCard(
                margin: const EdgeInsets.only(bottom: AppSpacing.lg),
                child: Row(
                  children: [
                    Icon(Icons.lock_outline, color: colors.danger),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        'Аккаунт заблокирован после критической экстренной блокировки.',
                        style: text.caption.copyWith(color: colors.danger),
                      ),
                    ),
                  ],
                ),
              ),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, color: colors.warning),
                  const SizedBox(height: AppSpacing.md),
                  Text('Важно', style: text.sectionTitle),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Ключ восстановления позволит вернуть доступ к аккаунту при потере устройства. '
                    'Храните его офлайн. Генерация и синхронизация с сервером пока недоступны.',
                    style: text.secondary,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Статус', style: text.caption),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    _recoveryLock ? 'Требуется восстановление' : 'Не настроен',
                    style: text.title.copyWith(color: _recoveryLock ? colors.danger : colors.textMuted),
                  ),
                ],
              ),
            ),
            const Spacer(),
            if (_recoveryLock) ...[
              AppButton(label: 'Снять блокировку (MVP)', onPressed: _clearRecoveryLock),
              const SizedBox(height: AppSpacing.md),
            ],
            AppButton(
              label: 'Сгенерировать ключ',
              variant: _recoveryLock ? AppButtonVariant.secondary : AppButtonVariant.primary,
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Функция в разработке — backend не подключён')),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
