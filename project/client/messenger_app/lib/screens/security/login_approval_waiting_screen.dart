import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_button.dart';
import '../../core/ui/app_card.dart';
import '../../state/app_controller.dart';

/// Shown on a new device until a trusted device approves the login.
class LoginApprovalWaitingScreen extends ConsumerStatefulWidget {
  const LoginApprovalWaitingScreen({super.key});

  @override
  ConsumerState<LoginApprovalWaitingScreen> createState() => _LoginApprovalWaitingScreenState();
}

class _LoginApprovalWaitingScreenState extends ConsumerState<LoginApprovalWaitingScreen> {
  bool _checking = false;

  Future<void> _checkStatus() async {
    setState(() => _checking = true);
    await ref.read(appControllerProvider).recheckLoginApproval();
    if (mounted) setState(() => _checking = false);
  }

  Future<void> _logout() async {
    await ref.read(appControllerProvider).logout();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final session = ref.watch(appControllerProvider).session;
    final deviceId = session?.deviceId ?? '';

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          child: Column(
            children: [
              const Spacer(),
              Icon(Icons.phonelink_lock_outlined, size: 72, color: colors.primary),
              const SizedBox(height: AppSpacing.xl),
              Text('Ожидание подтверждения', style: text.largeTitle, textAlign: TextAlign.center),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Новый вход с этого устройства. Подтвердите вход на доверенном устройстве или отклоните запрос.',
                style: text.caption,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xl),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Это устройство', style: text.caption),
                    const SizedBox(height: 4),
                    Text(defaultTargetPlatform.name, style: text.subtitle),
                    const SizedBox(height: AppSpacing.sm),
                    Text('ID', style: text.caption),
                    const SizedBox(height: 4),
                    Text(deviceId, style: text.body.copyWith(fontSize: 12)),
                  ],
                ),
              ),
              const Spacer(),
              AppButton(
                label: _checking ? 'Проверка…' : 'Проверить статус',
                loading: _checking,
                onPressed: _checking ? null : _checkStatus,
              ),
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: 'Выйти',
                variant: AppButtonVariant.secondary,
                onPressed: _logout,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
