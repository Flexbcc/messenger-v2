import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_button.dart';
import '../../core/ui/app_card.dart';
import '../../models/contact_trust.dart';
import '../../services/security_meta_store.dart';
import '../../state/app_controller.dart';

/// Key verification UI — safety number / fingerprint (crypto wiring later).
class VerifyContactScreen extends ConsumerWidget {
  const VerifyContactScreen({
    super.key,
    required this.userId,
    required this.displayName,
  });

  final String userId;
  final String displayName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final text = context.textStyles;
    final trust = ref.watch(appControllerProvider).trustLevelFor(userId);

    return Scaffold(
      appBar: AppBar(title: Text(displayName)),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        child: Column(
          children: [
            AppCard(
              child: Column(
                children: [
                  Icon(Icons.qr_code_2, size: 120, color: colors.textMuted),
                  const SizedBox(height: AppSpacing.lg),
                  Text('Сканировать QR', style: text.sectionTitle),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Сравните ключи с собеседником лично или по защищённому каналу.',
                    style: text.caption,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(Icons.numbers, color: colors.textSecondary),
                    title: Text('Safety number', style: text.subtitle),
                    subtitle: Text('AB12 CD34 EF56 …', style: text.caption),
                  ),
                  Divider(height: 1, color: colors.divider),
                  ListTile(
                    leading: Icon(
                      Icons.fingerprint,
                      color: colors.textSecondary,
                    ),
                    title: Text('Сравнить отпечаток', style: text.subtitle),
                    subtitle: Text(
                      'Скоро — требуется backend',
                      style: text.caption,
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            if (trust.index < TrustLevel.trusted.index)
              AppButton(
                label: 'Отметить как доверенный',
                onPressed: () async {
                  await ref
                      .read(appControllerProvider)
                      .setContactTrustLevel(userId, TrustLevel.trusted);
                  await SecurityMetaStore.instance.recordContactVerification();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Контакт отмечен как доверенный'),
                      ),
                    );
                    Navigator.pop(context);
                  }
                },
              )
            else
              AppButton(
                label: 'Уже доверенный контакт',
                variant: AppButtonVariant.secondary,
                onPressed: null,
              ),
          ],
        ),
      ),
    );
  }
}
