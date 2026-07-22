import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_button.dart';
import '../../core/ui/app_card.dart';
import '../../security/recovery_key_service.dart';
import '../../services/emergency_lock_service.dart';
import '../../state/app_controller.dart';

/// Recovery key management — generate, display, and verify the local key.
class RecoveryKeyScreen extends ConsumerStatefulWidget {
  const RecoveryKeyScreen({super.key});

  @override
  ConsumerState<RecoveryKeyScreen> createState() => _RecoveryKeyScreenState();
}

class _RecoveryKeyScreenState extends ConsumerState<RecoveryKeyScreen> {
  bool _loading = true;
  bool _recoveryLock = false;
  String? _existingKey;
  bool _revealed = false;
  bool _verifying = false;
  final _verifyController = TextEditingController();
  String? _verifyResult;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _verifyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final locked = await EmergencyLockService.instance.isRecoveryLockActive();
    final key = await RecoveryKeyService.instance.load();
    if (!mounted) return;
    setState(() {
      _recoveryLock = locked;
      _existingKey = key;
      _loading = false;
    });
  }

  Future<void> _generate() async {
    final colors = context.colors;
    if (_existingKey != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Заменить ключ?'),
          content: const Text(
            'Старый ключ будет удалён безвозвратно. '
            'Убедитесь, что сохранили копию старого ключа.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Заменить', style: TextStyle(color: colors.danger)),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    final key = await RecoveryKeyService.instance.generate();
    if (!mounted) return;
    setState(() {
      _existingKey = key;
      _revealed = true;
      _verifyResult = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Ключ сгенерирован — сохраните его в надёжном месте')),
    );
  }

  Future<void> _clearRecoveryLock() async {
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Снять блокировку?'),
        content: const Text('Убедитесь, что аккаунт в безопасности.'),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Блокировка восстановления снята')),
      );
    }
  }

  Future<void> _doVerify() async {
    final candidate = _verifyController.text.trim();
    if (candidate.isEmpty) return;
    final ok = await RecoveryKeyService.instance.verify(candidate);
    if (!mounted) return;
    setState(() {
      _verifyResult = ok ? 'Ключ верный ✓' : 'Ключ не совпадает ✗';
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Ключ восстановления')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final formattedKey = _existingKey != null ? RecoveryKeyService.format(_existingKey!) : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Ключ восстановления')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Emergency lock banner
            if (_recoveryLock)
              AppCard(
                margin: const EdgeInsets.only(bottom: AppSpacing.lg),
                child: Row(
                  children: [
                    Icon(Icons.lock_outline, color: colors.danger),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Аккаунт заблокирован', style: text.subtitle.copyWith(color: colors.danger)),
                          const SizedBox(height: 2),
                          Text('После экстренной блокировки требуется восстановление.', style: text.caption),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

            // Info card
            AppCard(
              margin: const EdgeInsets.only(bottom: AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.shield_outlined, color: colors.warning),
                      const SizedBox(width: AppSpacing.sm),
                      Text('Ключ восстановления', style: text.sectionTitle),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Ключ хранится только на устройстве в защищённом хранилище (Keychain / Keystore). '
                    'Запишите его офлайн — это единственный способ подтвердить владение аккаунтом '
                    'после полной потери устройства.',
                    style: text.secondary,
                  ),
                ],
              ),
            ),

            // Key display
            if (_existingKey != null) ...[
              AppCard(
                margin: const EdgeInsets.only(bottom: AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('Ваш ключ', style: text.caption),
                        const Spacer(),
                        IconButton(
                          icon: Icon(
                            _revealed ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                            size: 18,
                          ),
                          onPressed: () => setState(() => _revealed = !_revealed),
                          tooltip: _revealed ? 'Скрыть' : 'Показать',
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy_outlined, size: 18),
                          tooltip: 'Копировать',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: formattedKey!));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Ключ скопирован')),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: colors.border),
                      ),
                      child: Text(
                        _revealed ? (formattedKey ?? '') : '●●●●●●  ●●●●●●  ●●●●●●  ●●●●●●',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 18,
                          letterSpacing: 2,
                          color: _revealed ? colors.textPrimary : colors.textSecondary,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    if (_revealed)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.sm),
                        child: Text(
                          'Запишите этот ключ и храните офлайн. Не отправляйте никому.',
                          style: text.caption.copyWith(color: colors.warning),
                          textAlign: TextAlign.center,
                        ),
                      ),
                  ],
                ),
              ),

              // Verify section
              if (!_verifying)
                Align(
                  alignment: Alignment.center,
                  child: TextButton(
                    onPressed: () => setState(() { _verifying = true; _verifyResult = null; }),
                    child: const Text('Проверить мой ключ'),
                  ),
                )
              else
                AppCard(
                  margin: const EdgeInsets.only(bottom: AppSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Проверка ключа', style: text.subtitle),
                      const SizedBox(height: AppSpacing.sm),
                      TextField(
                        controller: _verifyController,
                        decoration: const InputDecoration(
                          hintText: 'XXXXXX-XXXXXX-XXXXXX-XXXXXX',
                          border: OutlineInputBorder(),
                        ),
                        style: const TextStyle(fontFamily: 'monospace', letterSpacing: 1.5),
                        textCapitalization: TextCapitalization.characters,
                        onSubmitted: (_) => _doVerify(),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      if (_verifyResult != null)
                        Text(
                          _verifyResult!,
                          style: TextStyle(
                            color: _verifyResult!.contains('✓') ? colors.success : colors.danger,
                            fontWeight: FontWeight.w500,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => setState(() { _verifying = false; _verifyResult = null; }),
                              child: const Text('Отмена'),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _doVerify,
                              child: const Text('Проверить'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: AppSpacing.lg),
            ] else ...[
              AppCard(
                margin: const EdgeInsets.only(bottom: AppSpacing.lg),
                child: Column(
                  children: [
                    Icon(Icons.key_off_outlined, size: 48, color: colors.textMuted),
                    const SizedBox(height: AppSpacing.md),
                    Text('Ключ не создан', style: text.title),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'Создайте ключ восстановления, чтобы не потерять доступ к аккаунту.',
                      style: text.secondary,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ],

            if (_recoveryLock) ...[
              AppButton(
                label: 'Снять блокировку восстановления',
                variant: AppButtonVariant.secondary,
                onPressed: _clearRecoveryLock,
              ),
              const SizedBox(height: AppSpacing.md),
            ],

            AppButton(
              label: _existingKey != null ? 'Перегенерировать ключ' : 'Сгенерировать ключ',
              variant: _existingKey != null ? AppButtonVariant.secondary : AppButtonVariant.primary,
              onPressed: _generate,
            ),
          ],
        ),
      ),
    );
  }
}
