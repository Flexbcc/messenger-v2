import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_tile.dart';
import '../models/settings_catalog.dart';
import '../state/settings_catalog_controller.dart';
import '../state/theme_settings.dart';
import '../widgets/setting_title_label.dart';
import 'settings_catalog_section_screen.dart';

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  static const _options = [
    (ThemeMode.system, 'Как в системе', Icons.brightness_auto_outlined),
    (ThemeMode.light, 'Светлая', Icons.light_mode_outlined),
    (ThemeMode.dark, 'Тёмная', Icons.dark_mode_outlined),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final themeSettings = ref.watch(themeSettingsProvider);
    final catalogAsync = ref.watch(settingsCatalogProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Оформление')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SettingsStubLegend(),
                  const SizedBox(height: AppSpacing.sm),
                  Text('Тема — рабочая. Остальное из спеки.', style: context.textStyles.caption),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Тема',
            children: [
              for (var i = 0; i < _options.length; i++)
                AppTile(
                  leading: Icon(_options[i].$3, color: colors.textSecondary),
                  title: _options[i].$2,
                  trailing: themeSettings.mode == _options[i].$1
                      ? Icon(Icons.check_circle, color: colors.primary, size: 20)
                      : null,
                  showDivider: i < _options.length - 1,
                  onTap: () => ref.read(themeSettingsProvider).setMode(_options[i].$1),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          catalogAsync.when(
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
            data: (catalog) {
              final values = ref.watch(settingsCatalogValuesProvider);
              if (!values.loaded) {
                ref.read(settingsCatalogValuesProvider).load(catalog);
              }
              return AppSettingsGroup(
                title: 'Дополнительно (спека)',
                children: [
                  _catalogSelect(context, ref, catalog, 'appearance.text_size', 'Размер текста'),
                  _catalogBool(context, ref, catalog, 'appearance.compact', 'Компактный режим'),
                  _catalogBool(context, ref, catalog, 'appearance.animations', 'Анимации'),
                  _catalogBool(context, ref, catalog, 'appearance.reduce_motion', 'Уменьшить движение'),
                  _catalogSelect(context, ref, catalog, 'appearance.chat_bubbles', 'Пузыри чата', last: true),
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.lg),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
            child: AppCard(
              padding: EdgeInsets.zero,
              child: AppTile(
                title: 'Все настройки раздела',
                subtitle: 'appearance — полный список из каталога',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsCatalogSectionScreen(sectionId: 'appearance')),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _catalogBool(BuildContext context, WidgetRef ref, SettingsCatalog catalog, String id, String label, {bool last = false}) {
    final def = catalog.settingById(id);
    if (def == null) return const SizedBox.shrink();
    final values = ref.watch(settingsCatalogValuesProvider);
    final value = values.loaded ? values.valueOf(def) == true : def.defaultValue == true;
    return AppTile(
      title: label,
      titleWidget: SettingTitleLabel(settingId: id, title: label),
      trailing: Switch.adaptive(
        value: value,
        onChanged: values.loaded
            ? (v) => ref.read(settingsCatalogValuesProvider).setValue(def, v)
            : null,
      ),
      showDivider: !last,
      onTap: values.loaded
          ? () => ref.read(settingsCatalogValuesProvider).setValue(def, !value)
          : null,
    );
  }

  Widget _catalogSelect(BuildContext context, WidgetRef ref, SettingsCatalog catalog, String id, String label, {bool last = false}) {
    final def = catalog.settingById(id);
    if (def == null) return const SizedBox.shrink();
    final values = ref.watch(settingsCatalogValuesProvider);
    final raw = values.loaded ? values.valueOf(def)?.toString() ?? '' : def.defaultValue?.toString() ?? '';
    return AppTile(
      title: label,
      titleWidget: SettingTitleLabel(settingId: id, title: label),
      trailingText: raw,
      trailing: AppTile.chevron(context),
      showDivider: !last,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SettingsCatalogSectionScreen(sectionId: 'appearance')),
      ),
    );
  }
}
