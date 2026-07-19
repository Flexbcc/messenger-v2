import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/platform/platform_capabilities.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_avatar.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_switch_tile.dart';
import '../core/ui/app_tile.dart';
import '../services/local_settings_store.dart';
import '../services/privacy_setup_summary.dart';
import '../state/app_controller.dart';
import '../state/notification_settings.dart';
import '../state/theme_settings.dart';
import 'about_screen.dart';
import 'account_screen.dart';
import 'appearance_screen.dart';
import 'contacts_screen.dart';
import 'data_storage_screen.dart';
import 'debug_log_screen.dart';
import 'diagnostics_screen.dart';
import 'devices_screen.dart';
import 'discoverability_settings_screen.dart';
import 'help_screen.dart';
import 'notes_screen.dart';
import 'notifications_screen.dart';
import 'private_mode/confidentiality_hub_screen.dart';
import 'profile_screen.dart';
import 'scheduled_messages_screen.dart';
import 'security/connection_status_screen.dart';
import 'security/login_approval_screen.dart';
import 'security/recovery_key_screen.dart';
import 'security/security_dashboard_screen.dart';
import 'security/security_log_screen.dart';
import 'web_calls_help_screen.dart';

/// Settings hub — thematic groups; developer section unlocked by 10 title taps.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  PrivacySetupSummary? _privacy;
  bool _privacyLoading = true;
  bool _developerMode = false;
  int _titleTaps = 0;

  static const _developerKey = 'settings_developer_mode';

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await ref.read(notificationSettingsProvider).refreshPrivacyOverrides();
      await ref.read(appControllerProvider).refreshDevices();
      final summary = await PrivacySetupSummary.load();
      final developer = await LocalSettingsStore().getBool(_developerKey, false);
      if (!mounted) return;
      setState(() {
        _privacy = summary;
        _privacyLoading = false;
        _developerMode = developer;
      });
    });
  }

  Future<void> _onTitleTap() async {
    if (_developerMode) return;
    _titleTaps++;
    if (_titleTaps >= 10) {
      _titleTaps = 0;
      await LocalSettingsStore().setBool(_developerKey, true);
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      setState(() => _developerMode = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Режим разработчика включён')),
      );
    } else if (_titleTaps >= 7) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ещё ${10 - _titleTaps}…'), duration: const Duration(milliseconds: 600)),
      );
    }
  }

  Future<void> _openConfidentiality() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConfidentialityHubScreen()));
    final summary = await PrivacySetupSummary.load();
    if (mounted) setState(() => _privacy = summary);
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final themeSettings = ref.watch(themeSettingsProvider);
    final notifSettings = ref.watch(notificationSettingsProvider);
    final session = controller.session;
    final colors = context.colors;
    final text = context.textStyles;
    final p = _privacy;

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: _onTitleTap,
          behavior: HitTestBehavior.opaque,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Text('Настройки'),
          ),
        ),
      ),
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
            title: 'Аккаунт',
            children: [
              AppTile(
                leading: Icon(Icons.person_outline, color: colors.textSecondary),
                title: 'Аккаунт',
                subtitle: 'Имя, телефон, выход',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen())),
              ),
              AppTile(
                leading: Icon(Icons.travel_explore_outlined, color: colors.textSecondary),
                title: 'Кто может найти',
                subtitle: 'Поиск по username, телефону, почте',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DiscoverabilitySettingsScreen()),
                ),
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Интерфейс',
            children: [
              AppTile(
                leading: Icon(Icons.palette_outlined, color: colors.textSecondary),
                title: 'Оформление',
                trailingText: '${themeSettings.modeLabel} · ${themeSettings.textScaleLabel}',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AppearanceScreen())),
              ),
              AppTile(
                leading: Icon(Icons.notifications_outlined, color: colors.textSecondary),
                title: 'Уведомления',
                subtitle: notifSettings.sounds ? 'Звук включён' : 'Без звука',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotificationsScreen())),
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Безопасность',
            children: [
              AppTile(
                leading: Icon(Icons.security_outlined, color: colors.primary),
                title: 'Центр безопасности',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SecurityDashboardScreen())),
              ),
              AppTile(
                leading: Icon(Icons.devices_outlined, color: colors.textSecondary),
                title: 'Устройства и сеансы',
                trailingText: controller.devices.isNotEmpty ? '${controller.devices.length}' : null,
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DevicesScreen())),
              ),
              AppTile(
                leading: Icon(Icons.phonelink_lock_outlined, color: colors.textSecondary),
                title: 'Подтверждение входа',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginApprovalScreen())),
              ),
              AppTile(
                leading: Icon(Icons.key_outlined, color: colors.textSecondary),
                title: 'Ключ восстановления',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RecoveryKeyScreen())),
              ),
              AppTile(
                leading: Icon(Icons.contacts_outlined, color: colors.textSecondary),
                title: 'Контакты и доверие E2E',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ContactsScreen())),
              ),
              AppTile(
                leading: Icon(Icons.history, color: colors.textSecondary),
                title: 'Журнал безопасности',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SecurityLogScreen())),
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          if (_privacyLoading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.screenPadding),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            AppSettingsGroup(
              title: 'Конфиденциальность',
              children: [
                AppTile(
                  leading: Icon(Icons.shield_outlined, color: colors.secondary),
                  title: 'Конфиденциальность',
                  subtitle: p?.progressLabel ?? 'PIN, фейковый PIN, секретная комната',
                  trailing: AppTile.chevron(context),
                  onTap: _openConfidentiality,
                  showDivider: false,
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
                    ? 'В списке · ${controller.favoritesCount}'
                    : 'Показывать в списке чатов',
                value: controller.favoritesChatEnabled,
                onChanged: controller.setFavoritesChatEnabled,
                showDivider: true,
              ),
              AppTile(
                leading: Icon(Icons.schedule_outlined, color: colors.textSecondary),
                title: 'Отложенные',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ScheduledMessagesScreen())),
              ),
              AppTile(
                leading: Icon(Icons.note_alt_outlined, color: colors.textSecondary),
                title: 'Заметки',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotesScreen())),
                showDivider: false,
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
              if (PlatformCapabilities.isWeb)
                AppTile(
                  leading: Icon(Icons.call_outlined, color: colors.textSecondary),
                  title: 'Звонки в браузере',
                  subtitle: Uri.base.scheme == 'https' ? 'HTTPS · можно звонить' : 'Нужен HTTPS',
                  trailing: AppTile.chevron(context),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WebCallsHelpScreen())),
                  showDivider: false,
                )
              else
                AppTile(
                  leading: Icon(Icons.call_outlined, color: colors.textSecondary),
                  title: 'Звонки',
                  subtitle: 'Доступны в приложении',
                  showDivider: false,
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
                showDivider: false,
              ),
            ],
          ),
          if (_developerMode) ...[
            const SizedBox(height: AppSpacing.lg),
            AppSettingsGroup(
              title: 'Для разработчиков',
              children: [
                AppTile(
                  leading: Icon(Icons.bug_report_outlined, color: colors.textSecondary),
                  title: 'Журнал отладки',
                  trailing: AppTile.chevron(context),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DebugLogScreen())),
                ),
                AppTile(
                  leading: Icon(Icons.monitor_heart_outlined, color: colors.textSecondary),
                  title: 'Диагностика',
                  trailing: AppTile.chevron(context),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DiagnosticsScreen())),
                ),
                AppTile(
                  leading: Icon(Icons.lock_reset, color: colors.danger),
                  title: 'Скрыть раздел разработчика',
                  danger: true,
                  showDivider: false,
                  onTap: () async {
                    await LocalSettingsStore().setBool(_developerKey, false);
                    setState(() {
                      _developerMode = false;
                      _titleTaps = 0;
                    });
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
