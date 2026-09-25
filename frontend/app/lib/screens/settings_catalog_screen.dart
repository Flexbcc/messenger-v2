import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_empty_state.dart';
import '../core/ui/app_tile.dart';
import '../models/settings_blocks.dart';
import '../models/settings_impl_status.dart';
import '../state/settings_catalog_controller.dart';
import '../widgets/setting_title_label.dart';
import 'settings_catalog_block_screen.dart';
import 'settings_catalog_json_screen.dart';
import 'settings_catalog_section_screen.dart';

/// Extended settings from the product spec — grouped by thematic blocks.
class SettingsCatalogScreen extends ConsumerStatefulWidget {
  const SettingsCatalogScreen({super.key});

  @override
  ConsumerState<SettingsCatalogScreen> createState() =>
      _SettingsCatalogScreenState();
}

class _SettingsCatalogScreenState extends ConsumerState<SettingsCatalogScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(_refreshFromLegacy);
  }

  Future<void> _refreshFromLegacy() async {
    final catalog = await ref.read(settingsCatalogProvider.future);
    final values = ref.read(settingsCatalogValuesProvider);
    if (values.loaded) {
      await values.reloadFromLegacy(catalog);
    } else {
      await values.load(catalog);
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalogAsync = ref.watch(settingsCatalogProvider);
    final colors = context.colors;
    final text = context.textStyles;

    return Scaffold(
      appBar: AppBar(title: const Text('Расширенные настройки')),
      body: catalogAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => AppEmptyState(
          icon: Icons.settings_backup_restore_outlined,
          title: 'Настройки не загрузились',
          subtitle: 'Повторите попытку. Сохранённые значения не изменены.',
          actionLabel: 'Повторить',
          onAction: () => ref.invalidate(settingsCatalogProvider),
        ),
        data: (catalog) {
          final values = ref.watch(settingsCatalogValuesProvider);
          if (!values.loaded) {
            ref.read(settingsCatalogValuesProvider).load(catalog);
            return const Center(child: CircularProgressIndicator());
          }

          final visibleSettings = catalog.sections.expand(
            productionVisibleSettings,
          );
          final total = visibleSettings.length;
          final allIds = visibleSettings.map((d) => d.id);
          final stubs = SettingsImplStatus.stubCount(allIds);
          final verified = SettingsImplStatus.verifiedCount(allIds);
          final wired = SettingsImplStatus.wiredUnverifiedCount(allIds);

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
                      Text(
                        kDebugMode
                            ? '$total настроек · $verified проверено · $wired ожидают аудита · $stubs неполных'
                            : '$total настроек',
                        style: text.subtitle,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      const SettingsStubLegend(),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              for (var i = 0; i < kSettingsBlocks.length; i++)
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
                      leading: Icon(
                        kSettingsBlocks[i].icon,
                        color: colors.textSecondary,
                      ),
                      title: kSettingsBlocks[i].title,
                      subtitle:
                          '${kSettingsBlocks[i].settingCount(catalog)} · ${kSettingsBlocks[i].subtitle}',
                      trailing: AppTile.chevron(context),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SettingsCatalogBlockScreen(
                            blockId: kSettingsBlocks[i].id,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (kDebugMode) ...[
                const SizedBox(height: AppSpacing.md),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.screenPadding,
                  ),
                  child: AppCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        AppTile(
                          leading: Icon(
                            Icons.data_object,
                            color: colors.textSecondary,
                          ),
                          title: 'JSON всех значений',
                          trailing: AppTile.chevron(context),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const SettingsCatalogJsonScreen(),
                            ),
                          ),
                        ),
                        AppTile(
                          leading: Icon(
                            Icons.list_alt,
                            color: colors.textSecondary,
                          ),
                          title: 'Плоский список разделов',
                          trailing: AppTile.chevron(context),
                          showDivider: false,
                          onTap: () => _showFlatSections(context, catalog),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  void _showFlatSections(BuildContext context, catalog) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Все разделы')),
          body: ListView(
            children: [
              for (final section in catalog.sections)
                ListTile(
                  title: Text(section.title),
                  subtitle: Text('${section.settings.length} · ${section.id}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          SettingsCatalogSectionScreen(sectionId: section.id),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
