import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_controller.dart';
import '../theme/app_decorations.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';
import '../widgets/app_button.dart';
import '../widgets/app_card.dart';
import '../widgets/avatar.dart';
import '../widgets/status_dot.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    final session = controller.session;

    return Scaffold(
      appBar: AppBar(title: const Text('Профиль')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        children: [
          Center(
            child: AppAvatar(label: session?.displayName ?? '?', size: AppAvatarSize.large),
          ),
          const SizedBox(height: AppSpacing.mediumGap),
          Center(child: Text(session?.displayName ?? '', style: AppTypography.largeTitle)),
          const SizedBox(height: AppSpacing.smallGap),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const StatusDot(status: AppStatus.online, diameter: 8),
                const SizedBox(width: 6),
                Text('В сети', style: AppTypography.caption),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sectionGap),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _QuickAction(icon: Icons.chat_bubble_outline, label: 'Написать', onTap: () => Navigator.pop(context)),
              _QuickAction(icon: Icons.call_outlined, label: 'Позвонить', onTap: () {}),
              _QuickAction(icon: Icons.videocam_outlined, label: 'Видео', onTap: () {}),
              _QuickAction(icon: Icons.more_horiz, label: 'Ещё', onTap: () {}),
            ],
          ),
          const SizedBox(height: AppSpacing.sectionGap),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('User ID', style: AppTypography.caption.copyWith(color: AppColors.textMuted)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: SelectableText(session?.userId ?? '', style: AppTypography.body.copyWith(fontSize: 13)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy_outlined, size: 18, color: AppColors.textSecondary),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: session?.userId ?? ''));
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Скопировано')));
                      },
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.smallGap),
                Text(
                  'Поделитесь ID, чтобы начать защищённый чат.',
                  style: AppTypography.caption,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.mediumGap),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.badge_outlined, color: AppColors.textSecondary),
                  title: Text('Имя', style: AppTypography.subtitle),
                  subtitle: Text(session?.displayName ?? '', style: AppTypography.caption),
                ),
                const Divider(height: 1, color: AppColors.divider),
                ListTile(
                  leading: const Icon(Icons.lock_outline, color: AppColors.accentBlue),
                  title: Text('Шифрование', style: AppTypography.subtitle),
                  subtitle: Text('Сквозное E2E на устройстве', style: AppTypography.caption),
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      gradient: AppDecorations.accentGradient,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('ON', style: AppTypography.micro.copyWith(fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sectionGap),
          AppButton(
            label: 'Выйти',
            variant: AppButtonVariant.danger,
            onPressed: () => controller.logout(),
          ),
        ],
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.medium),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.cardSecondary,
                borderRadius: BorderRadius.circular(AppRadii.medium),
              ),
              child: Icon(icon, color: AppColors.accentBlue, size: 22),
            ),
            const SizedBox(height: 6),
            Text(label, style: AppTypography.micro),
          ],
        ),
      ),
    );
  }
}
