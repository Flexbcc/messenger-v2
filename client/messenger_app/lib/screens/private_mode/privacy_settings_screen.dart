import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/platform/platform_capabilities.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_bottom_sheet.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_switch_tile.dart';
import '../../core/ui/app_tile.dart';
import '../../services/app_lock_service.dart';
import '../../services/privacy_preferences_store.dart';
import 'hidden_chats_settings_screen.dart';
import 'device_privacy_screen.dart';
import 'pin_setup_screen.dart';
import 'private_mode_state.dart';

class PrivacySettingsScreen extends ConsumerStatefulWidget {
  const PrivacySettingsScreen({super.key});

  @override
  ConsumerState<PrivacySettingsScreen> createState() => _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends ConsumerState<PrivacySettingsScreen> {
  final _store = PrivacyPreferencesStore();
  bool _loading = true;

  bool _faceId = false;
  bool _fakePinEnabled = false;
  bool _secretRoomEnabled = true;
  bool _hiddenChatsEnabled = true;
  bool _maskNotifications = false;
  bool _hidePreviews = false;
  bool _appLock = false;
  bool _wipeOnWrongAttempts = false;
  String _autoLock = '1 минута';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final pm = ref.read(privateModeStateProvider);
    setState(() => _loading = true);

    final fakePin = await _store.fakePinEnabled();
    final secretRoom = await _store.secretRoomEnabled();
    final hiddenChats = await _store.hiddenChatsEnabled();
    final mask = await _store.maskNotifications();
    final hide = await _store.hidePreviews();
    final appLock = await _store.appLockEnabled();
    final wipe = await _store.wipeOnWrongAttempts();
    final autoSec = await _store.autoLockSeconds();

    if (!mounted) return;
    setState(() {
      _faceId = pm.biometricEnabled;
      _fakePinEnabled = fakePin;
      _secretRoomEnabled = secretRoom;
      _hiddenChatsEnabled = hiddenChats;
      _maskNotifications = mask;
      _hidePreviews = hide;
      _appLock = appLock;
      _wipeOnWrongAttempts = wipe;
      _autoLock = PrivacyPreferencesStore.labelForSeconds(autoSec);
      _loading = false;
    });
  }

  Future<void> _confirmWipeToggle(bool newValue) async {
    final colors = context.colors;
    if (!newValue) {
      await _store.setWipeOnWrongAttempts(false);
      setState(() => _wipeOnWrongAttempts = false);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Включить очистку данных?'),
        content: const Text(
          'После нескольких неверных попыток ввода PIN данные Private Mode будут удалены. '
          'Это необратимо и только на этом устройстве.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Включить', style: TextStyle(color: colors.danger)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _store.setWipeOnWrongAttempts(true);
      setState(() => _wipeOnWrongAttempts = true);
    }
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
    if (picked != null) {
      final seconds = PrivacyPreferencesStore.autoLockLabels[picked] ?? 60;
      await _store.setAutoLockSeconds(seconds);
      setState(() => _autoLock = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки приватности')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          if (PlatformCapabilities.isWeb)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: AppCard(
                child: Text(
                  'Веб-версия: биометрия недоступна, хранилище — в localStorage браузера. '
                  'Все экраны доступны для просмотра.',
                  style: text.caption.copyWith(color: colors.warning),
                ),
              ),
            ),
          AppSettingsGroup(
            title: 'Доступ',
            children: [
              AppTile(
                leading: Icon(Icons.pin_outlined, color: colors.textSecondary),
                title: 'PIN',
                subtitle: 'Изменить основной PIN',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PinSetupScreen())),
              ),
              AppSwitchTile(
                leading: Icon(Icons.fingerprint, color: colors.textSecondary),
                title: 'Face ID / Touch ID',
                subtitle: PlatformCapabilities.isWeb ? 'Mock на web' : 'Биометрический вход',
                value: _faceId,
                enabled: true,
                onChanged: (v) async {
                  await ref.read(privateModeStateProvider).setBiometricEnabled(v);
                  setState(() => _faceId = v);
                },
              ),
              AppSwitchTile(
                leading: Icon(Icons.theater_comedy_outlined, color: colors.textSecondary),
                title: 'Fake PIN',
                subtitle: 'Обманный PIN → фейк-режим',
                value: _fakePinEnabled,
                onChanged: (v) async {
                  await _store.setFakePinEnabled(v);
                  setState(() => _fakePinEnabled = v);
                },
              ),
              AppSwitchTile(
                leading: Icon(Icons.lock_open_outlined, color: colors.textSecondary),
                title: 'Secret Room',
                value: _secretRoomEnabled,
                onChanged: (v) async {
                  await _store.setSecretRoomEnabled(v);
                  setState(() => _secretRoomEnabled = v);
                },
              ),
              AppSwitchTile(
                leading: Icon(Icons.visibility_off_outlined, color: colors.textSecondary),
                title: 'Скрытые чаты',
                value: _hiddenChatsEnabled,
                onChanged: (v) async {
                  await _store.setHiddenChatsEnabled(v);
                  setState(() => _hiddenChatsEnabled = v);
                },
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
                subtitle: 'Скрывает текст в баннерах',
                value: _maskNotifications,
                onChanged: (v) async {
                  await _store.setMaskNotifications(v);
                  setState(() => _maskNotifications = v);
                },
              ),
              AppSwitchTile(
                leading: Icon(Icons.preview_outlined, color: colors.textSecondary),
                title: 'Скрытие превью',
                value: _hidePreviews,
                onChanged: (v) async {
                  await _store.setHidePreviews(v);
                  setState(() => _hidePreviews = v);
                },
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Блокировка',
            children: [
              AppSwitchTile(
                leading: Icon(Icons.lock_clock_outlined, color: colors.textSecondary),
                title: 'Блокировка приложения',
                value: _appLock,
                onChanged: (v) async {
                  await _store.setAppLockEnabled(v);
                  await AppLockService.instance.refreshEnabled();
                  setState(() => _appLock = v);
                },
              ),
              AppTile(
                leading: Icon(Icons.timer_outlined, color: colors.textSecondary),
                title: 'Авто-блокировка',
                trailingText: _autoLock,
                trailing: AppTile.chevron(context),
                onTap: _pickAutoLock,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Устройства',
            children: [
              AppTile(
                leading: Icon(Icons.devices_outlined, color: colors.textSecondary),
                title: 'Приватность устройств',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DevicePrivacyScreen())),
              ),
              AppTile(
                leading: Icon(Icons.tune_outlined, color: colors.textSecondary),
                title: 'Настройки скрытых чатов',
                trailing: AppTile.chevron(context),
                showDivider: false,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HiddenChatsSettingsScreen())),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Опасная зона', style: text.sectionTitle.copyWith(color: colors.danger)),
                  const SizedBox(height: AppSpacing.sm),
                  AppSwitchTile(
                    title: 'Очистка при ошибочных попытках',
                    subtitle: 'После 5 неверных PIN — сброс Private Mode',
                    value: _wipeOnWrongAttempts,
                    onChanged: _confirmWipeToggle,
                    showDivider: false,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
