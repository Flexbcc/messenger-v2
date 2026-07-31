import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ui/app_card.dart';
import '../core/ui/app_switch_tile.dart';
import '../models/settings_catalog.dart';
import '../models/settings_impl_status.dart';
import '../state/settings_catalog_controller.dart';
import 'setting_title_label.dart';

/// Catalog-backed toggle for legacy screens — shows red * when stub.
class CatalogBoolTile extends ConsumerWidget {
  const CatalogBoolTile({
    super.key,
    required this.settingId,
    required this.title,
    this.subtitle,
  });

  final String settingId;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalogAsync = ref.watch(settingsCatalogProvider);
    return catalogAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (catalog) {
        final def = catalog.settingById(settingId);
        if (def == null) return const SizedBox.shrink();
        final values = ref.watch(settingsCatalogValuesProvider);
        if (!values.loaded) {
          ref.read(settingsCatalogValuesProvider).load(catalog);
          return const SizedBox.shrink();
        }
        final value = values.valueOf(def) == true;
        final stubNote = SettingsImplStatus.isStub(settingId)
            ? ' · неполная'
            : SettingsImplStatus.isWiredUnverified(settingId)
            ? ' · ожидает аудита'
            : null;
        return AppCard(
          padding: EdgeInsets.zero,
          child: AppSwitchTile(
            title: title,
            titleWidget: SettingTitleLabel(settingId: settingId, title: title),
            subtitle: subtitle ?? stubNote,
            value: value,
            onChanged: (v) =>
                ref.read(settingsCatalogValuesProvider).setValue(def, v),
          ),
        );
      },
    );
  }
}

/// Wraps AppTile title with asterisk for stub settings.
Widget catalogTileTitle(String id, String title, TextStyle? style) =>
    SettingTitleLabel(settingId: id, title: title, style: style);

String catalogSectionSubtitle(CatalogSection section) {
  final ids = section.settings.map((s) => s.id);
  final stubs = SettingsImplStatus.stubCount(ids);
  final verified = SettingsImplStatus.verifiedCount(ids);
  final wired = SettingsImplStatus.wiredUnverifiedCount(ids);
  return '${section.settings.length} · $verified проверено · $wired на аудите · $stubs неполных';
}
