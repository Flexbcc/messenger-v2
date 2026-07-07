import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_avatar.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_switch_tile.dart';
import '../core/ui/app_tile.dart';
import '../state/app_controller.dart';
import '../state/notification_settings.dart';
import '../state/theme_settings.dart';
import 'about_screen.dart';
import 'account_screen.dart';
import 'appearance_screen.dart';
import 'data_storage_screen.dart';
import 'debug_log_screen.dart';
import 'diagnostics_screen.dart';
import 'devices_screen.dart';
import 'help_screen.dart';
import 'notifications_screen.dart';
import 'private_mode/private_mode_entry.dart';
import 'profile_screen.dart';
import 'security/connection_status_screen.dart';
import 'notes_screen.dart';
import 'scheduled_messages_screen.dart';
import 'security/security_dashboard_screen.dart';

/// Settings hub — grouped by user intent (security, account, chats, system).
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await ref.read(notificationSettingsProvider).refreshPrivacyOverrides();
      await ref.read(appControllerProvider).refreshDevices();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final themeSettings = ref.watch(themeSettingsProvider);
    final notifSettings = ref.watch(notificationSettingsProvider);
    final session = controller.session;
    final deviceCount = controller.devices.length;
    final colors = context.colors;
    final text = context.textStyles;

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
            child: AppCard(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProfileScreen())),
              child: Row(
                children: [
                  AppAvatar(label: session?.displayName, size: AppAvatarSize.large),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(session?.displayName ?? '', style: text.title),
                        Text('Профиль и User ID', style: text.caption),
                      ],
                    ),
                  ),
                  AppTile.chevron(context),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          AppSettingsGroup(
            title: 'Безопасность',
            children: [
              AppTile(
                leading: Icon(Icons.security_outlined, color: colors.primary),
                title: 'Центр безопасности',
                subtitle: 'E2E, PIN, recovery, журнал',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SecurityDashboardScreen())),
              ),
              AppTile(
                leading: Icon(Icons.lock_outline, color: colors.secondary),
                title: 'Конфиденциальность',
                subtitle: 'Private Mode, скрытые чаты, PIN',
                trailing: AppTile.chevron(context),
                onTap: () async {
                  await Navigator.of(context).push(privateModeEntryRoute());
                  if (mounted) await ref.read(notificationSettingsProvider).refreshPrivacyOverrides();
                },
              ),
              AppTile(
                leading: Icon(Icons.devices_outlined, color: colors.textSecondary),
                title: 'Устройства и сеансы',
                subtitle: 'Доверие, вход с новых устройств',
                trailingText: deviceCount > 0 ? '$deviceCount' : null,
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DevicesScreen())),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Аккаунт',
            children: [
              AppTile(
                leading: Icon(Icons.person_outline, color: colors.textSecondary),
                title: 'Аккаунт',
                subtitle: 'Имя, телефон, выход',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen())),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Интерфейс',
            children: [
              AppTile(
                leading: Icon(Icons.notifications_outlined, color: colors.textSecondary),
                title: 'Уведомления',
                subtitle: notifSettings.sounds ? 'Звук включён' : 'Без звука',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotificationsScreen())),
              ),
              AppTile(
                leading: Icon(Icons.palette_outlined, color: colors.textSecondary),
                title: 'Оформление',
                trailingText: themeSettings.modeLabel,
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AppearanceScreen())),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Чаты и сообщения',
            children: [
              AppSwitchTile(
                title: 'Чат «Избранное»',
                subtitle: controller.favoritesCount > 0
                    ? 'В списке чатов · ${controller.favoritesCount} сохранённых'
                    : 'Показывать в списке чатов при наличии',
                value: controller.favoritesChatEnabled,
                onChanged: (v) => controller.setFavoritesChatEnabled(v),
                showDivider: true,
              ),
              AppTile(
                leading: Icon(Icons.schedule_outlined, color: colors.textSecondary),
                title: 'Отложенные',
                subtitle: controller.scheduledMessageCount > 0
                    ? '${controller.scheduledMessageCount} ожидают отправки'
                    : 'Кнопка часов в чате',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ScheduledMessagesScreen())),
              ),
              AppTile(
                leading: Icon(Icons.note_alt_outlined, color: colors.textSecondary),
                title: 'Заметки',
                subtitle: 'Личные записи на устройстве',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotesScreen())),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Система',
            children: [
              AppTile(
                leading: Icon(Icons.storage_outlined, color: colors.textSecondary),
                title: 'Данные и хранилище',
                subtitle: 'Кэш, очистка истории',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DataStorageScreen())),
              ),
              AppTile(
                leading: Icon(Icons.wifi_tethering, color: colors.textSecondary),
                title: 'Состояние соединения',
                subtitle: controller.websocketConnected ? 'WebSocket активен' : 'Только REST',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConnectionStatusScreen())),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Справка',
            children: [
              AppTile(
                leading: Icon(Icons.help_outline, color: colors.textSecondary),
                title: 'Помощь',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HelpScreen())),
              ),
              AppTile(
                leading: Icon(Icons.info_outline, color: colors.textSecondary),
                title: 'О приложении',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AboutScreen())),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Для разработчиков',
            children: [
              AppTile(
                leading: Icon(Icons.bug_report_outlined, color: colors.textSecondary),
                title: 'Журнал отладки',
                subtitle: 'API, prekey, отправка',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DebugLogScreen())),
              ),
              AppTile(
                leading: Icon(Icons.monitor_heart_outlined, color: colors.textSecondary),
                title: 'Диагностика',
                subtitle: 'Очередь, WS, последняя ошибка',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DiagnosticsScreen())),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
