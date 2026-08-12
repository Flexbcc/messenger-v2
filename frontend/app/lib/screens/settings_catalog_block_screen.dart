import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_tile.dart';
import '../models/settings_blocks.dart';
import '../state/settings_catalog_controller.dart';
import '../widgets/catalog_setting_tiles.dart';
import '../widgets/setting_title_label.dart';
import 'settings_catalog_section_screen.dart';

/// One thematic block — lists catalog sections inside it.
class SettingsCatalogBlockScreen extends ConsumerWidget {
  const SettingsCatalogBlockScreen({super.key, required this.blockId});

  final String blockId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final block = settingsBlockById(blockId);
    if (block == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Раздел')),
        body: const Center(child: Text('Блок не найден')),
      );
    }

    final catalogAsync = ref.watch(settingsCatalogProvider);
    final text = context.textStyles;

    return Scaffold(
      appBar: AppBar(title: Text(block.title)),
      body: catalogAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Ошибка: $e')),
        data: (catalog) {
          final values = ref.watch(settingsCatalogValuesProvider);
          if (!values.loaded) {
            ref.read(settingsCatalogValuesProvider).load(catalog);
          }
          final sections = block.sections(catalog);
          return ListView(
            padding: const EdgeInsets.only(bottom: AppSpacing.xl),
            children: [
              const SizedBox(height: AppSpacing.md),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.screenPadding,
                ),
                child: AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(block.subtitle, style: text.body),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        '${block.settingCount(catalog)} настроек · ${sections.length} разделов спеки',
                        style: text.caption,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      const SettingsStubLegend(),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              for (var i = 0; i < sections.length; i++)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.screenPadding,
                    0,
                    AppSpacing.screenPadding,
                    AppSpacing.sm,
                  ),
                  child: AppCard(
                    padding: EdgeInsets.zero,
                    child: AppTile(
                      title: sections[i].title,
                      subtitle: catalogSectionSubtitle(sections[i]),
                      trailing: AppTile.chevron(context),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SettingsCatalogSectionScreen(
                            sectionId: sections[i].id,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
