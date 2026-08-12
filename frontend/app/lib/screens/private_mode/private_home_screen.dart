import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/platform/platform_capabilities.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_tile.dart';
import '../../services/privacy_preferences_store.dart';
import 'hidden_chats_screen.dart';
import '../secret_chat_settings_screen.dart';
import 'duress_policy_screen.dart';
import 'panic.dart';
import 'privacy_settings_screen.dart';
import 'private_feature_route.dart';
import 'private_mode_state.dart';
import 'private_devices_screen.dart';
import '../security/security_log_screen.dart';

/// Private Mode hub after successful PIN unlock.
class PrivateHomeScreen extends ConsumerWidget {
  const PrivateHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final text = context.textStyles;
    final access = ref.watch(privateModeStateProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Private'),
        actions: [
          IconButton(
            tooltip: 'Быстрый выход',
            icon: const Icon(Icons.close),
            onPressed: () => panicExit(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.shield_outlined, color: colors.secondary),
                      const SizedBox(width: AppSpacing.sm),
                      Text('Защищённое пространство', style: text.sectionTitle),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Раздел виден только после ввода PIN. На веб часть функций работает в упрощённом режиме.',
                    style: text.caption,
                  ),
                  if (PlatformCapabilities.isWeb) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      PlatformCapabilities.unavailableHint('Биометрия'),
                      style: text.micro.copyWith(color: colors.warning),
                    ),
                  ],
                ],
              ),
            ),
          ),
          AppSettingsGroup(
            title: 'Разделы',
            children: [
              if (access.canUseSecretFeatures) ...[
                AppTile(
                  leading: Icon(
                    Icons.chat_bubble_outline,
                    color: colors.textSecondary,
                  ),
                  title: 'Скрытые чаты',
                  trailing: AppTile.chevron(context),
                  onTap: () async {
                    final enabled = await PrivacyPreferencesStore()
                        .hiddenChatsEnabled();
                    if (!context.mounted) return;
                    if (!enabled) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Скрытые чаты отключены в настройках приватности',
                          ),
                        ),
                      );
                      return;
                    }
                    Navigator.of(context).push(
                      privateSecretRoute((_) => const HiddenChatsScreen()),
                    );
                  },
                ),
                AppTile(
                  leading: Icon(
                    Icons.policy_outlined,
                    color: colors.textSecondary,
                  ),
                  title: 'Политика безопасности',
                  trailing: AppTile.chevron(context),
                  onTap: () => Navigator.of(
                    context,
                  ).push(privateSecretRoute((_) => const DuressPolicyScreen())),
                  showDivider: true,
                ),
              ],
              AppTile(
                leading: Icon(Icons.tune_outlined, color: colors.textSecondary),
                title: 'Настройки приватности',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const PrivacySettingsScreen(),
                  ),
                ),
                showDivider: true,
              ),
              if (access.canUseSecretFeatures) ...[
                AppTile(
                  leading: Icon(
                    Icons.lock_person_outlined,
                    color: colors.textSecondary,
                  ),
                  title: 'Секретная комната',
                  trailing: AppTile.chevron(context),
                  onTap: () => Navigator.of(context).push(
                    privateSecretRoute((_) => const SecretChatSettingsScreen()),
                  ),
                  showDivider: true,
                ),
                AppTile(
                  leading: Icon(
                    Icons.devices_outlined,
                    color: colors.textSecondary,
                  ),
                  title: 'Приватные устройства',
                  trailing: AppTile.chevron(context),
                  onTap: () => Navigator.of(context).push(
                    privateSecretRoute((_) => const PrivateDevicesScreen()),
                  ),
                ),
              ],
              AppTile(
                leading: Icon(Icons.history, color: colors.textSecondary),
                title: 'Журнал безопасности',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SecurityLogScreen()),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Backward-compatible alias.
typedef SecretRoomScreen = PrivateHomeScreen;
