import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_bottom_sheet.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_switch_tile.dart';
import '../core/ui/app_tile.dart';
import '../core/platform/platform_capabilities.dart';
import '../services/os_notification_service.dart';
import '../state/app_controller.dart';
import '../state/notification_settings.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  static const _previewOptions = [
    'Полный текст',
    'Только имя отправителя',
    'Только приложение',
    'Скрыто',
  ];
  static const _channelOptions = [
    'Все сообщения',
    'Только упоминания',
    'Выключено',
  ];
  static const _callsOptions = ['Все', 'Только контакты', 'Выключено'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final text = context.textStyles;
    final settings = ref.watch(notificationSettingsProvider);
    if (!settings.loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Уведомления')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenPadding,
            ),
            child: AppCard(
              child: Text(
                PlatformCapabilities.isWeb
                    ? 'Web Push работает и при закрытой вкладке. Сервер передаёт '
                          'только тип события — без имени, текста и содержимого сообщения.'
                    : 'Локальные уведомления macOS/desktop. Remote push — на стороне бэкенда.',
                style: text.caption,
              ),
            ),
          ),
          if (PlatformCapabilities.browserNotificationsAvailable) ...[
            const SizedBox(height: AppSpacing.lg),
            AppSettingsGroup(
              title: 'Браузер',
              children: [
                AppTile(
                  leading: Icon(
                    Icons.notifications_active_outlined,
                    color: colors.textSecondary,
                  ),
                  title: 'Разрешить уведомления',
                  subtitle:
                      OsNotificationService.instance.permission == 'granted'
                      ? 'Разрешено'
                      : 'Нужно для оповещений, когда вкладка в фоне',
                  trailing: AppTile.chevron(context),
                  onTap: () async {
                    final ok = await OsNotificationService.instance
                        .requestPermission();
                    if (ok && !settings.enabled) {
                      await settings.setEnabled(true);
                    }
                    String? error;
                    if (ok) {
                      try {
                        await ref.read(appControllerProvider).enableWebPush();
                      } catch (e) {
                        error = e.toString();
                      }
                    }
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            ok && error == null
                                ? 'Уведомления и Web Push включены'
                                : ok
                                ? 'Разрешение есть, но Web Push не зарегистрирован: $error'
                                : 'Разрешение не получено',
                          ),
                        ),
                      );
                    }
                  },
                  showDivider: false,
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Общие',
            children: [
              AppSwitchTile(
                leading: Icon(
                  Icons.notifications_outlined,
                  color: colors.textSecondary,
                ),
                title: 'Уведомления',
                subtitle: 'Главный переключатель уведомлений приложения',
                value: settings.enabled,
                onChanged: (enabled) async {
                  await settings.setEnabled(enabled);
                  if (!enabled) {
                    await ref.read(appControllerProvider).disableWebPush();
                  }
                },
              ),
              AppSwitchTile(
                leading: Icon(
                  Icons.volume_up_outlined,
                  color: colors.textSecondary,
                ),
                title: 'Звуки',
                value: settings.sounds,
                onChanged: settings.setSounds,
              ),
              AppSwitchTile(
                leading: Icon(
                  Icons.vibration_outlined,
                  color: colors.textSecondary,
                ),
                title: 'Вибрация',
                value: settings.vibration,
                onChanged: settings.setVibration,
              ),
              AppTile(
                leading: Icon(
                  Icons.preview_outlined,
                  color: colors.textSecondary,
                ),
                title: 'Предпросмотр',
                trailingText: settings.preview,
                trailing: AppTile.chevron(context),
                onTap: () => _pickValue(
                  context,
                  title: 'Предпросмотр',
                  options: _previewOptions,
                  current: settings.preview,
                  onSelected: settings.setPreview,
                ),
              ),
              AppSwitchTile(
                leading: Icon(Icons.chat_outlined, color: colors.textSecondary),
                title: 'Уведомления в чате',
                subtitle: 'Звук и баннер, когда открыт этот чат',
                value: settings.inChat,
                onChanged: settings.setInChat,
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'По типу чата',
            children: [
              AppTile(
                leading: Icon(
                  Icons.person_outline,
                  color: colors.textSecondary,
                ),
                title: 'Личные чаты',
                trailingText: settings.directChats,
                trailing: AppTile.chevron(context),
                onTap: () => _pickValue(
                  context,
                  title: 'Личные чаты',
                  options: _channelOptions,
                  current: settings.directChats,
                  onSelected: settings.setDirectChats,
                ),
              ),
              AppTile(
                leading: Icon(
                  Icons.groups_outlined,
                  color: colors.textSecondary,
                ),
                title: 'Группы',
                trailingText: settings.groups,
                trailing: AppTile.chevron(context),
                onTap: () => _pickValue(
                  context,
                  title: 'Группы',
                  options: _channelOptions,
                  current: settings.groups,
                  onSelected: settings.setGroups,
                ),
              ),
              AppTile(
                leading: Icon(Icons.lock_outline, color: colors.secondary),
                title: 'Private',
                subtitle: 'Локально скрытые диалоги',
                trailingText: settings.privateChats,
                trailing: AppTile.chevron(context),
                onTap: () => _pickValue(
                  context,
                  title: 'Private чаты',
                  options: _channelOptions,
                  current: settings.privateChats,
                  onSelected: settings.setPrivateChats,
                ),
              ),
              AppTile(
                leading: Icon(
                  Icons.visibility_off_outlined,
                  color: colors.secondary,
                ),
                title: 'Hidden Chats',
                trailingText: settings.hiddenChats,
                trailing: AppTile.chevron(context),
                showDivider: false,
                onTap: () => _pickValue(
                  context,
                  title: 'Hidden Chats',
                  options: _channelOptions,
                  current: settings.hiddenChats,
                  onSelected: settings.setHiddenChats,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            children: [
              AppTile(
                leading: Icon(Icons.call_outlined, color: colors.textSecondary),
                title: 'Звонки',
                trailingText: settings.calls,
                trailing: AppTile.chevron(context),
                showDivider: false,
                onTap: () => _pickValue(
                  context,
                  title: 'Звонки',
                  options: _callsOptions,
                  current: settings.calls,
                  onSelected: settings.setCalls,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickValue(
    BuildContext context, {
    required String title,
    required List<String> options,
    required String current,
    required Future<void> Function(String) onSelected,
  }) async {
    final colors = context.colors;
    final text = context.textStyles;

    final selected = await showAppBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: Text(title, style: text.title),
            ),
            for (final option in options)
              ListTile(
                title: Text(option, style: text.body),
                trailing: option == current
                    ? Icon(Icons.check, color: colors.primary)
                    : null,
                onTap: () => Navigator.of(context).pop(option),
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
    if (selected != null) await onSelected(selected);
  }
}
