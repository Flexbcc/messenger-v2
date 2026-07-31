import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_switch_tile.dart';
import '../core/ui/app_tile.dart';
import '../models/settings_catalog.dart';
import '../services/catalog_list_store.dart';
import '../services/settings_catalog_actions.dart';
import '../state/catalog_runtime_values.dart';
import '../state/settings_catalog_controller.dart';
import '../utils/setting_option_labels.dart';
import '../widgets/setting_title_label.dart';

/// Renders a single catalog section: every setting becomes the right control
/// for its `type`, honoring `visible_if` dependencies. Values persist via
/// [SettingsCatalogValues] and sync to runtime through the catalog bridge.
class SettingsCatalogSectionScreen extends ConsumerWidget {
  const SettingsCatalogSectionScreen({super.key, required this.sectionId});

  final String sectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalogAsync = ref.watch(settingsCatalogProvider);
    final values = ref.watch(settingsCatalogValuesProvider);
    final text = context.textStyles;

    return catalogAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('Ошибка: $e', style: text.body)),
      ),
      data: (catalog) {
        final section = catalog.sectionById(sectionId);
        if (section == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: Text('Раздел не найден: $sectionId', style: text.body),
            ),
          );
        }
        if (!values.loaded) {
          ref.read(settingsCatalogValuesProvider).load(catalog);
          return Scaffold(
            appBar: AppBar(title: Text(section.title)),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        final runtimeAsync = ref.watch(catalogRuntimeValuesProvider);
        final runtime =
            runtimeAsync.valueOrNull ?? const CatalogRuntimeValues();
        var visible = section.settings.where(values.isVisible).toList();
        if (sectionId == 'developer' &&
            values.valueById('developer.enabled') != true) {
          visible = visible
              .where(
                (s) =>
                    s.id == 'developer.enabled' ||
                    s.id == 'developer.protocol_version',
              )
              .toList();
        }
        final actions = SettingsCatalogActions(
          context: context,
          ref: ref,
          listStore: CatalogListStore(),
        );
        return Scaffold(
          appBar: AppBar(title: Text(section.title)),
          body: ListView(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenPadding,
              vertical: AppSpacing.md,
            ),
            children: [
              const SettingsStubLegend(),
              const SizedBox(height: AppSpacing.md),
              for (var i = 0; i < visible.length; i++) ...[
                _buildSetting(
                  context,
                  ref,
                  values,
                  runtime,
                  actions,
                  visible[i],
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildSetting(
    BuildContext context,
    WidgetRef ref,
    SettingsCatalogValues values,
    CatalogRuntimeValues runtime,
    SettingsCatalogActions actions,
    SettingDef def,
  ) {
    final controller = ref.read(settingsCatalogValuesProvider);
    final value = values.valueOf(def);
    final runtimeValue = runtime.valueFor(def.id);

    final titleW = SettingTitleLabel(settingId: def.id, title: def.title);

    if (def.isSecret) {
      return AppCard(
        padding: EdgeInsets.zero,
        child: AppTile(
          title: def.title,
          titleWidget: titleW,
          subtitle: def.description.isEmpty
              ? 'Нажмите для настройки'
              : def.description,
          trailing: AppTile.chevron(context),
          onTap: () => actions.openSecret(def),
        ),
      );
    }

    switch (def.type) {
      case 'boolean':
        return AppCard(
          padding: EdgeInsets.zero,
          child: AppSwitchTile(
            title: def.title,
            titleWidget: titleW,
            subtitle: _subtitle(def),
            value: value == true,
            onChanged: (v) => controller.setValue(def, v),
          ),
        );

      case 'single_select':
        return AppCard(
          padding: EdgeInsets.zero,
          child: AppTile(
            title: def.title,
            titleWidget: titleW,
            subtitle: _subtitle(def),
            trailingText: _labelForOption(def, value?.toString()),
            onTap: () async {
              final picked = await _pickSingle(context, def, value?.toString());
              if (picked != null) controller.setValue(def, picked);
            },
          ),
        );

      case 'multi_select':
        final selected = (value is List)
            ? value.map((e) => e.toString()).toList()
            : <String>[];
        return AppCard(
          padding: EdgeInsets.zero,
          child: AppTile(
            title: def.title,
            titleWidget: titleW,
            subtitle: selected.isEmpty
                ? _subtitle(def, fallback: 'Не выбрано')
                : selected.map((e) => _labelForOption(def, e)).join(', '),
            trailing: AppTile.chevron(context),
            onTap: () async {
              final picked = await _pickMulti(context, def, selected);
              if (picked != null) controller.setValue(def, picked);
            },
          ),
        );

      case 'number':
        return AppCard(
          padding: EdgeInsets.zero,
          child: AppTile(
            title: def.title,
            titleWidget: titleW,
            subtitle: _subtitle(def),
            trailingText: (value ?? '').toString(),
            onTap: () async {
              final entered = await _editText(
                context,
                def,
                value?.toString() ?? '',
                number: true,
              );
              if (entered != null) {
                controller.setValue(def, int.tryParse(entered) ?? 0);
              }
            },
          ),
        );

      case 'text':
        return AppCard(
          padding: EdgeInsets.zero,
          child: AppTile(
            title: def.title,
            titleWidget: titleW,
            subtitle: _subtitle(def),
            trailingText: (value?.toString().isEmpty ?? true)
                ? 'задать'
                : value.toString(),
            onTap: () async {
              final entered = await _editText(
                context,
                def,
                value?.toString() ?? '',
              );
              if (entered != null) controller.setValue(def, entered);
            },
          ),
        );

      case 'read_only':
        final display = runtimeValue ?? value?.toString() ?? '—';
        return AppCard(
          padding: EdgeInsets.zero,
          child: AppTile(
            title: def.title,
            titleWidget: titleW,
            subtitle: _subtitle(def),
            trailingText: display,
            enabled: false,
          ),
        );

      case 'action':
        return AppCard(
          padding: EdgeInsets.zero,
          child: AppTile(
            title: def.title,
            titleWidget: titleW,
            subtitle: _subtitle(def),
            danger: def.danger,
            trailing: AppTile.chevron(context),
            onTap: () => actions.runAction(def),
          ),
        );

      case 'list':
        return AppCard(
          padding: EdgeInsets.zero,
          child: AppTile(
            title: def.title,
            titleWidget: titleW,
            subtitle: _subtitle(
              def,
              fallback: 'Нажмите для редактирования списка',
            ),
            trailing: AppTile.chevron(context),
            onTap: () => actions.editList(def),
          ),
        );

      default:
        return AppCard(
          padding: EdgeInsets.zero,
          child: AppTile(
            title: def.title,
            titleWidget: titleW,
            subtitle: def.description,
            trailingText: def.type,
            onTap: () => actions.runAction(def),
          ),
        );
    }
  }

  String? _friendlyDescription(SettingDef def) {
    final d = def.description.trim();
    if (d.isEmpty) return null;
    final lower = d.toLowerCase();
    if (lower.startsWith('switch ') ||
        lower.startsWith('choice of ') ||
        lower.startsWith('information description') ||
        lower.contains('value true') ||
        lower.contains('json_type') ||
        lower.contains('из фиксированного списка')) {
      return null;
    }
    return d;
  }

  String? _subtitle(SettingDef def, {String? fallback}) {
    return _friendlyDescription(def) ?? fallback;
  }

  String _labelForOption(SettingDef def, String? raw) {
    if (raw == null || raw.isEmpty) return '';
    return settingOptionLabel(raw);
  }

  Future<String?> _pickSingle(
    BuildContext context,
    SettingDef def,
    String? current,
  ) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(def.title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_friendlyDescription(def) != null) ...[
                Text(
                  _friendlyDescription(def)!,
                  style: context.textStyles.caption,
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              for (final opt in def.options)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_labelForOption(def, opt)),
                  trailing: opt == current
                      ? Icon(Icons.check, color: context.colors.primary)
                      : null,
                  onTap: () => Navigator.of(ctx).pop(opt),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Отмена'),
          ),
        ],
      ),
    );
  }

  Future<List<String>?> _pickMulti(
    BuildContext context,
    SettingDef def,
    List<String> current,
  ) {
    final selected = {...current};
    return showDialog<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(def.title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_friendlyDescription(def) != null) ...[
                  Text(
                    _friendlyDescription(def)!,
                    style: context.textStyles.caption,
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                for (final opt in def.options)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.trailing,
                    value: selected.contains(opt),
                    title: Text(_labelForOption(def, opt)),
                    onChanged: (v) => setLocal(() {
                      if (v == true) {
                        selected.add(opt);
                      } else {
                        selected.remove(opt);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(selected.toList()),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _editText(
    BuildContext context,
    SettingDef def,
    String current, {
    bool number = false,
  }) {
    final ctrl = TextEditingController(text: current);
    String? error;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          return AlertDialog(
            title: Text(def.title),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: number
                  ? TextInputType.number
                  : def.format == 'email'
                  ? TextInputType.emailAddress
                  : def.format == 'phone'
                  ? TextInputType.phone
                  : TextInputType.text,
              inputFormatters: number
                  ? [FilteringTextInputFormatter.digitsOnly]
                  : null,
              maxLength: def.maxLength,
              decoration: InputDecoration(
                hintText: def.description,
                errorText: error,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Отмена'),
              ),
              TextButton(
                onPressed: () {
                  final validation = def.validateInput(
                    ctrl.text,
                    number: number,
                  );
                  if (validation != null) {
                    setLocal(() => error = validation);
                    return;
                  }
                  Navigator.of(ctx).pop(ctrl.text.trim());
                },
                child: const Text('OK'),
              ),
            ],
          );
        },
      ),
    );
  }
}
