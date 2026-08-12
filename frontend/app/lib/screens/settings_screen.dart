import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_avatar.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_switch_tile.dart';
import '../core/ui/app_tile.dart';
import '../models/settings_blocks.dart';
import '../models/settings_catalog.dart';
import '../state/app_controller.dart';
import '../state/notification_settings.dart';
import '../state/settings_catalog_controller.dart';
import '../state/theme_settings.dart';
import '../services/local_settings_store.dart';
import '../widgets/setting_title_label.dart';
import 'about_screen.dart';
import 'appearance_screen.dart';
import 'data_storage_screen.dart';
import 'devices_screen.dart';
import 'help_screen.dart';
import 'notes_screen.dart';
import 'notifications_screen.dart';
import 'private_mode/private_mode_entry.dart';
import 'private_mode/private_mode_state.dart';
import 'profile_screen.dart';
import 'scheduled_messages_screen.dart';
import 'security/connection_status_screen.dart';
import 'security/security_dashboard_screen.dart';
import 'settings_catalog_section_screen.dart';

/// Settings hub — everyday tiles + catalog sections in thematic groups (no separate “advanced” page).
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  static const _serviceModeKey = 'ui.service_settings_unlocked';
  final _localSettings = LocalSettingsStore();
  int _titleTapCount = 0;
  DateTime? _lastTitleTap;
  bool _serviceMode = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final unlocked = await _localSettings.getBool(_serviceModeKey, false);
      if (mounted) setState(() => _serviceMode = unlocked);
      await ref.read(notificationSettingsProvider).refreshPrivacyOverrides();
      await ref.read(appControllerProvider).refreshDevices();
      try {
        await ref.read(appControllerProvider).loadMyProfile();
      } catch (_) {
        // The settings hub remains usable offline with the cached session.
      }
    });
  }

  Future<void> _handleSettingsTitleTap() async {
    final now = DateTime.now();
    if (_lastTitleTap == null ||
        now.difference(_lastTitleTap!) > const Duration(seconds: 2)) {
      _titleTapCount = 0;
    }
    _lastTitleTap = now;
    _titleTapCount++;
    if (_titleTapCount < 10) return;
    _titleTapCount = 0;
    final enabled = !_serviceMode;
    await _localSettings.setBool(_serviceModeKey, enabled);
    if (!mounted) return;
    setState(() => _serviceMode = enabled);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          enabled
              ? 'Служебные настройки открыты'
              : 'Служебные настройки скрыты',
        ),
      ),
    );
  }

  Future<void> _openCatalogSection(String sectionId) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsCatalogSectionScreen(sectionId: sectionId),
      ),
    );
    if (mounted) {
      await ref.read(notificationSettingsProvider).refreshPrivacyOverrides();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final pmState = ref.watch(privateModeStateProvider);
    final themeSettings = ref.watch(themeSettingsProvider);
    final notifSettings = ref.watch(notificationSettingsProvider);
    final catalogAsync = ref.watch(settingsCatalogProvider);
    final session = controller.session;
    final deviceCount = controller.devices.length;
    final colors = context.colors;
    final text = context.textStyles;
    final pinConfigured = pmState.isConfigured;

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _handleSettingsTitleTap,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Настройки'),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenPadding,
            ),
            child: AppCard(
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const ProfileScreen())),
              child: Row(
                children: [
                  AppAvatar(
                    imageProvider: controller.profileAvatarBytes == null
                        ? null
                        : MemoryImage(controller.profileAvatarBytes!),
                    label: session?.displayName,
                    size: AppAvatarSize.large,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(session?.displayName ?? '', style: text.title),
                        Text(
                          'Имя, username, телефон, пароль',
                          style: text.caption,
                        ),
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
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SecurityDashboardScreen(),
                  ),
                ),
              ),
              AppTile(
                leading: Icon(Icons.lock_outline, color: colors.secondary),
                title: pinConfigured ? 'Приватный режим' : 'Блокировка и PIN',
                trailing: AppTile.chevron(context),
                onTap: () async {
                  await Navigator.of(context).push(privateModeEntryRoute());
                  if (mounted) {
                    await ref
                        .read(notificationSettingsProvider)
                        .refreshPrivacyOverrides();
                  }
                },
              ),
              AppTile(
                leading: Icon(
                  Icons.devices_outlined,
                  color: colors.textSecondary,
                ),
                title: 'Устройства и сеансы',
                trailingText: deviceCount > 0 ? '$deviceCount' : null,
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DevicesScreen()),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Оформление',
            children: [
              AppTile(
                leading: Icon(
                  Icons.notifications_outlined,
                  color: colors.textSecondary,
                ),
                title: 'Уведомления',
                subtitle: notifSettings.sounds ? 'Звук включён' : 'Без звука',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const NotificationsScreen(),
                  ),
                ),
              ),
              AppTile(
                leading: Icon(
                  Icons.palette_outlined,
                  color: colors.textSecondary,
                ),
                title: 'Тема и интерфейс',
                trailingText: themeSettings.modeLabel,
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AppearanceScreen()),
                ),
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
                leading: Icon(
                  Icons.schedule_outlined,
                  color: colors.textSecondary,
                ),
                title: 'Отложенные',
                subtitle: controller.scheduledMessageCount > 0
                    ? '${controller.scheduledMessageCount} ожидают отправки'
                    : null,
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ScheduledMessagesScreen(),
                  ),
                ),
              ),
              AppTile(
                leading: Icon(
                  Icons.note_alt_outlined,
                  color: colors.textSecondary,
                ),
                title: 'Заметки',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const NotesScreen())),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Система',
            children: [
              AppTile(
                leading: Icon(
                  Icons.storage_outlined,
                  color: colors.textSecondary,
                ),
                title: 'Данные и хранилище',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DataStorageScreen()),
                ),
              ),
              if (_serviceMode)
                AppTile(
                  leading: Icon(
                    Icons.wifi_tethering,
                    color: colors.textSecondary,
                  ),
                  title: 'Состояние соединения',
                  subtitle: controller.websocketConnected
                      ? 'Канал событий активен'
                      : 'Ограниченное соединение',
                  trailing: AppTile.chevron(context),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const ConnectionStatusScreen(),
                    ),
                  ),
                ),
            ],
          ),
          ...catalogAsync.when(
            loading: () => const [SizedBox.shrink()],
            error: (_, __) => const [SizedBox.shrink()],
            data: (catalog) {
              final values = ref.watch(settingsCatalogValuesProvider);
              if (!values.loaded) {
                ref.read(settingsCatalogValuesProvider).load(catalog);
              }
              return _catalogGroups(context, catalog);
            },
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Справка',
            children: [
              AppTile(
                leading: Icon(Icons.help_outline, color: colors.textSecondary),
                title: 'Помощь',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const HelpScreen())),
              ),
              AppTile(
                leading: Icon(Icons.info_outline, color: colors.textSecondary),
                title: 'О приложении',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const AboutScreen())),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _catalogGroups(BuildContext context, SettingsCatalog catalog) {
    final colors = context.colors;
    final out = <Widget>[];
    // Skip sections that have a dedicated rich screen on the hub:
    // profile/identity → ProfileScreen, appearance → AppearanceScreen,
    // devices → DevicesScreen, notifications → NotificationsScreen,
    // data/backup → DataStorageScreen, security/hidden_chats → SecurityDashboardScreen.
    for (final block in kSettingsBlocks) {
      final sections = block
          .sections(catalog)
          .where(
            (section) =>
                !kDedicatedSettingsSections.containsKey(section.id) &&
                (_serviceMode ||
                    !kServiceSettingsSectionIds.contains(section.id)),
          )
          .toList();
      if (sections.isEmpty) continue;
      out.add(const SizedBox(height: AppSpacing.lg));
      out.add(
        AppSettingsGroup(
          title: block.title,
          children: [
            for (var i = 0; i < sections.length; i++)
              AppTile(
                leading: Icon(
                  block.icon,
                  color: colors.textSecondary,
                  size: 22,
                ),
                title: sections[i].title,
                subtitle: _sectionSubtitle(sections[i].id),
                trailing: AppTile.chevron(context),
                showDivider: i < sections.length - 1,
                onTap: () => _openCatalogSection(sections[i].id),
              ),
          ],
        ),
      );
    }
    if (_serviceMode) {
      out.add(const SizedBox(height: AppSpacing.sm));
      out.add(
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
          child: SettingsStubLegend(),
        ),
      );
    }
    return out;
  }

  static String? _sectionSubtitle(String id) {
    switch (id) {
      case 'privacy':
        return 'Поиск, онлайн-статус, приглашения';
      case 'security':
        return 'Ключи смены, блокировка при атаке';
      case 'hidden_chats':
        return 'Скрытые диалоги и PIN-доступ';
      case 'contacts':
        return 'Доверие, блокировки, уровни';
      case 'notifications':
        return 'Звук, предпросмотр, типы';
      case 'messages':
        return 'Отправка Enter, черновики, ссылки';
      case 'calls':
        return 'Видео, запись статуса';
      case 'media':
        return 'Качество, лимиты загрузки';
      case 'data':
        return 'Кэш, экспорт, удаление';
      case 'backup':
        return 'Резервные копии ключей';
      case 'devices':
        return 'Активные сеансы, подтверждение входа';
      case 'node':
        return 'Адрес ноды, протокол';
      case 'sync':
        return 'Интервал, фоновая синхронизация';
      case 'storage_ownership':
        return 'Децентрализованное хранилище';
      case 'appearance':
        return 'Тема, размер текста, анимации';
      case 'developer':
        return 'Логи, отладка — включить developer.enabled';
      default:
        return null;
    }
  }
}
