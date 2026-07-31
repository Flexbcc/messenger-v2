import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/platform/platform_capabilities.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_switch_tile.dart';
import '../../core/ui/app_tile.dart';
import '../../services/privacy_preferences_store.dart';
import '../../services/privacy_setup_summary.dart';
import 'private_settings_access.dart';

/// Extra privacy tools — hidden chats & devices (duress lives in PIN/decoy/secret sections).
class PrivacyAdvancedSectionScreen extends ConsumerStatefulWidget {
  const PrivacyAdvancedSectionScreen({super.key});

  @override
  ConsumerState<PrivacyAdvancedSectionScreen> createState() => _PrivacyAdvancedSectionScreenState();
}

class _PrivacyAdvancedSectionScreenState extends ConsumerState<PrivacyAdvancedSectionScreen> {
  PrivacySetupSummary? _summary;
  bool _hidePreviews = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Future.microtask(_reload);
  }

  Future<void> _reload() async {
    final s = await PrivacySetupSummary.load();
    final hide = await PrivacyPreferencesStore().hidePreviews();
    if (!mounted) return;
    setState(() {
      _summary = s;
      _hidePreviews = hide;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final p = _summary;

    if (_loading || p == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Дополнительные')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl, top: AppSpacing.md),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
            child: AppCard(
              child: Text(
                'Рецепты защиты (оповещения, блокировки, очистка) — в разделах PIN. '
                'Здесь — скрытые чаты и устройства.',
                style: text.caption,
              ),
            ),
          ),
          if (PlatformCapabilities.isWeb) ...[
            const SizedBox(height: AppSpacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
              child: AppCard(
                child: Text(
                  'Веб-версия: защищённое хранилище работает в хранилище браузера, '
                  'а не в аппаратном secure enclave. Для максимальной защиты используйте мобильное приложение.',
                  style: text.caption.copyWith(color: colors.warning),
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          AppSettingsGroup(
            title: 'Скрытые чаты',
            children: [
              AppSwitchTile(
                leading: Icon(Icons.visibility_off_outlined, color: colors.textSecondary),
                title: 'Скрытые чаты',
                value: p.hiddenChatsEnabled,
                onChanged: (v) async {
                  await PrivacyPreferencesStore().setHiddenChatsEnabled(v);
                  await _reload();
                },
              ),
              AppTile(
                leading: Icon(Icons.settings_suggest_outlined, color: colors.textSecondary),
                title: 'Настройки скрытых чатов',
                subtitle: 'Команда в поиске, жест',
                trailing: AppTile.chevron(context),
                onTap: () => PrivateSettingsAccess.openHiddenChatsSettings(context),
              ),
              AppTile(
                leading: Icon(Icons.chat_bubble_outline, color: colors.textSecondary),
                title: 'Открыть скрытые чаты',
                trailing: AppTile.chevron(context),
                onTap: () => PrivateSettingsAccess.openHiddenChats(context),
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Устройства',
            children: [
              AppTile(
                leading: Icon(Icons.devices_other_outlined, color: colors.textSecondary),
                title: 'Приватные устройства',
                trailing: AppTile.chevron(context),
                onTap: () => PrivateSettingsAccess.openPrivateDevices(context),
              ),
              AppTile(
                leading: Icon(Icons.smartphone_outlined, color: colors.textSecondary),
                title: 'Приватность устройств',
                trailing: AppTile.chevron(context),
                onTap: () => PrivateSettingsAccess.openDevicePrivacy(context),
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Превью',
            children: [
              AppSwitchTile(
                leading: Icon(Icons.preview_outlined, color: colors.textSecondary),
                title: 'Скрытие превью',
                value: _hidePreviews,
                onChanged: (v) async {
                  await PrivacyPreferencesStore().setHidePreviews(v);
                  setState(() => _hidePreviews = v);
                },
                showDivider: false,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
