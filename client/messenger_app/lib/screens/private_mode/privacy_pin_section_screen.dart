import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/platform/platform_capabilities.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_bottom_sheet.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_switch_tile.dart';
import '../../core/ui/app_tile.dart';
import '../../models/duress_policy.dart';
import '../../services/app_lock_service.dart';
import '../../services/privacy_preferences_store.dart';
import '../../services/privacy_setup_summary.dart';
import '../../widgets/private/duress_behavior_card.dart';
import 'private_mode_state.dart';
import 'private_settings_access.dart';

/// Main PIN + lock + wrong-PIN behaviour settings.
class PrivacyPinSectionScreen extends ConsumerStatefulWidget {
  const PrivacyPinSectionScreen({super.key});

  @override
  ConsumerState<PrivacyPinSectionScreen> createState() => _PrivacyPinSectionScreenState();
}

class _PrivacyPinSectionScreenState extends ConsumerState<PrivacyPinSectionScreen> {
  PrivacySetupSummary? _summary;
  String _autoLock = '1 минута';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Future.microtask(_reload);
  }

  @override
  void dispose() {
    PrivateSettingsAccess.lockVault();
    super.dispose();
  }

  Future<void> _reload() async {
    await warmDuressMirror();
    final s = await PrivacySetupSummary.load();
    final prefs = PrivacyPreferencesStore();
    final sec = await prefs.autoLockSeconds();
    if (!mounted) return;
    setState(() {
      _summary = s;
      _autoLock = PrivacyPreferencesStore.labelForSeconds(sec);
      _loading = false;
    });
  }

  Future<void> _pickAutoLock() async {
    final colors = context.colors;
    final text = context.textStyles;
    final picked = await showAppBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final label in PrivacyPreferencesStore.autoLockLabels.keys)
              ListTile(
                title: Text(label, style: text.body),
                trailing: label == _autoLock ? Icon(Icons.check, color: colors.primary) : null,
                onTap: () => Navigator.pop(context, label),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await PrivacyPreferencesStore().setAutoLockSeconds(PrivacyPreferencesStore.autoLockLabels[picked] ?? 60);
    await AppLockService.instance.refreshAutoLockSeconds();
    setState(() => _autoLock = picked);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final pm = ref.watch(privateModeStateProvider);
    final p = _summary;

    if (_loading || p == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Основной PIN')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl, top: AppSpacing.md),
        children: [
          AppSettingsGroup(
            title: 'Код',
            children: [
              AppTile(
                leading: Icon(Icons.pin_outlined, color: colors.textSecondary),
                title: p.hasRealPin ? 'Изменить PIN' : 'Создать PIN',
                subtitle: p.hasRealPin ? 'Основной код доступа' : 'Обязательный первый шаг',
                trailing: AppTile.chevron(context),
                onTap: () async {
                  await PrivateSettingsAccess.openPinSetup(context);
                  await _reload();
                },
                showDivider: false,
              ),
            ],
          ),
          if (p.hasRealPin) ...[
            const SizedBox(height: AppSpacing.lg),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
              child: Text('Поведение при неверном PIN', style: text.sectionTitle),
            ),
            const SizedBox(height: AppSpacing.sm),
            const DuressBehaviorCard(
              title: 'Правила (неверный PIN)',
              trigger: DuressTrigger.pinUnlockFail,
            ),
            const SizedBox(height: AppSpacing.md),
            AppSettingsGroup(
              title: 'Настроить реакцию',
              children: [
                AppTile(
                  leading: Icon(Icons.shield_outlined, color: colors.textSecondary),
                  title: 'Рецепты защиты',
                  subtitle: 'Действие → условие → очередь шагов',
                  trailing: AppTile.chevron(context),
                  onTap: () async {
                    await PrivateSettingsAccess.openDuressPolicy(context, keepUnlocked: true);
                    await _reload();
                  },
                  showDivider: false,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            AppSettingsGroup(
              title: 'Блокировка приложения',
              children: [
                if (PlatformCapabilities.isWeb)
                  AppTile(
                    leading: Icon(Icons.info_outline, color: colors.warning),
                    title: 'Биометрия',
                    subtitle: PlatformCapabilities.unavailableHint('Face ID'),
                  )
                else
                  AppSwitchTile(
                    leading: Icon(Icons.fingerprint, color: colors.textSecondary),
                    title: 'Face ID / Touch ID',
                    value: pm.biometricEnabled,
                    onChanged: (v) => ref.read(privateModeStateProvider).setBiometricEnabled(v),
                  ),
                AppSwitchTile(
                  leading: Icon(Icons.lock_clock_outlined, color: colors.textSecondary),
                  title: 'Блокировка приложения',
                  subtitle: 'PIN при возврате в приложение',
                  value: p.appLockEnabled,
                  onChanged: (v) async {
                    await PrivacyPreferencesStore().setAppLockEnabled(v);
                    await AppLockService.instance.refreshEnabled();
                    await _reload();
                  },
                ),
                AppTile(
                  leading: Icon(Icons.timer_outlined, color: colors.textSecondary),
                  title: 'Авто-блокировка',
                  subtitle: 'По таймеру бездействия',
                  trailingText: _autoLock,
                  trailing: AppTile.chevron(context),
                  onTap: _pickAutoLock,
                  showDivider: false,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            AppSettingsGroup(
              title: 'Уведомления',
              children: [
                AppSwitchTile(
                  leading: Icon(Icons.notifications_off_outlined, color: colors.textSecondary),
                  title: 'Маскировка уведомлений',
                  value: p.maskNotifications,
                  onChanged: (v) async {
                    await PrivacyPreferencesStore().setMaskNotifications(v);
                    await _reload();
                  },
                  showDivider: false,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: AppCard(
                child: Text(
                  'Блокировка ввода, wipe vault и оповещения настраиваются рецептами в «Защите». '
                  'Очистка Private Mode — действие «Очистить Private Mode» в рецепте.',
                  style: text.caption,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
