import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_tile.dart';
import '../state/theme_settings.dart';

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

    return Scaffold(
      appBar: AppBar(title: const Text('Оформление')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          const SizedBox(height: AppSpacing.md),
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
          AppSettingsGroup(
            title: 'Размер текста',
            children: [
              for (var i = 0; i < ThemeSettings.textScaleOptions.length; i++)
                AppTile(
                  leading: Icon(Icons.format_size, color: colors.textSecondary),
                  title: ThemeSettings.textScaleOptions[i].$1,
                  trailing: (themeSettings.textScale - ThemeSettings.textScaleOptions[i].$2).abs() < 0.01
                      ? Icon(Icons.check_circle, color: colors.primary, size: 20)
                      : null,
                  showDivider: i < ThemeSettings.textScaleOptions.length - 1,
                  onTap: () => ref.read(themeSettingsProvider).setTextScale(ThemeSettings.textScaleOptions[i].$2),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
