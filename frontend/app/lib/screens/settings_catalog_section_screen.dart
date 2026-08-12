import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_switch_tile.dart';
import '../core/ui/app_tile.dart';
import '../models/settings_catalog.dart';
import '../models/settings_blocks.dart';
import '../services/catalog_list_store.dart';
import '../services/settings_catalog_actions.dart';
import '../state/catalog_runtime_values.dart';
import '../state/settings_catalog_controller.dart';
import '../utils/setting_option_labels.dart';
import '../utils/contact_field_format.dart';
import '../widgets/setting_title_label.dart';

/// Renders a single catalog section: every setting becomes the right control
/// for its `type`, honoring `visible_if` dependencies. Values persist via
/// [SettingsCatalogValues] and sync to runtime through the catalog bridge.
class SettingsCatalogSectionScreen extends ConsumerWidget {
  const SettingsCatalogSectionScreen({
    super.key,
    required this.sectionId,
    this.visibleSettingIds,
    this.titleOverride,
  });

  final String sectionId;

  /// Optional presentation filter for a dedicated parent screen. This keeps
  /// the catalog as the source of setting definitions without exposing
  /// actions that navigate back to that parent and create a route cycle.
  final Set<String>? visibleSettingIds;
  final String? titleOverride;

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
            appBar: AppBar(title: Text(titleOverride ?? section.title)),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        final runtimeAsync = ref.watch(catalogRuntimeValuesProvider);
        final runtime =
            runtimeAsync.valueOrNull ?? const CatalogRuntimeValues();
        var visible = section.settings.where(values.isVisible).toList();
        final embeddedIds = kEmbeddedCatalogSettingIds[sectionId];
        if (embeddedIds != null) {
          visible = visible
              .where((setting) => embeddedIds.contains(setting.id))
              .toList();
        }
        if (visibleSettingIds != null) {
          visible = visible
              .where((setting) => visibleSettingIds!.contains(setting.id))
              .toList();
        }
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
          appBar: AppBar(title: Text(titleOverride ?? section.title)),
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
        if (def.options.length <= 5) {
          return AppCard(
            padding: EdgeInsets.zero,
            child: AppTile(
              title: def.title,
              titleWidget: titleW,
              subtitle: _subtitle(def),
              trailing: PopupMenuButton<String>(
                tooltip: def.title,
                initialValue: value?.toString(),
                position: PopupMenuPosition.under,
                onSelected: (picked) => controller.setValue(def, picked),
                itemBuilder: (menuContext) => [
                  for (final option in def.options)
                    PopupMenuItem<String>(
                      value: option,
                      child: Row(
                        children: [
                          Expanded(child: Text(_labelForOption(def, option))),
                          if (option == value?.toString())
                            Icon(Icons.check, color: context.colors.primary),
                        ],
                      ),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.only(left: AppSpacing.sm),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _labelForOption(def, value?.toString()),
                        style: context.textStyles.caption.copyWith(
                          color: context.colors.textMuted,
                        ),
                      ),
                      const Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
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
        if (def.options.length <= 5) {
          return AppCard(
            padding: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.cardPadding,
                12,
                AppSpacing.cardPadding,
                12,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  titleW,
                  if (_subtitle(def) != null) ...[
                    const SizedBox(height: 2),
                    Text(_subtitle(def)!, style: context.textStyles.caption),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [
                      for (final option in def.options)
                        FilterChip(
                          label: Text(_labelForOption(def, option)),
                          selected: selected.contains(option),
                          onSelected: (enabled) {
                            final next = [...selected];
                            enabled ? next.add(option) : next.remove(option);
                            controller.setValue(def, next);
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }
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
            subtitle: _subtitle(def, fallback: _listPrompt(def.id)),
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
        lower.startsWith('переключатель') ||
        lower.startsWith('управляемый список') ||
        lower.startsWith('выбор из') ||
        lower.contains('value true') ||
        lower.contains('значение true') ||
        lower.contains('false отключает') ||
        lower.contains('json_type') ||
        lower.contains('из фиксированного списка')) {
      return null;
    }
    return d;
  }

  String? _subtitle(SettingDef def, {String? fallback}) {
    return _friendlyDescription(def) ?? fallback;
  }

  String _listPrompt(String id) {
    if (id.contains('users') ||
        id.contains('contacts') ||
        id.contains('allowlist') ||
        id.contains('trusted') ||
        id.contains('blocked') ||
        id.contains('visibility_list') ||
        id.contains('last_seen_list')) {
      return 'Выбрать контакты';
    }
    if (id.contains('chat')) return 'Выбрать чаты';
    if (id.contains('schedule')) return 'Настроить расписание';
    if (id.contains('node')) return 'Выбрать узлы';
    return 'Настроить список';
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
    final ctrl = TextEditingController(
      text: def.format == 'phone' ? formatPhoneNumber(current) : current,
    );
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
                  : def.format == 'phone'
                  ? const [PhoneNumberInputFormatter()]
                  : null,
              maxLength: def.maxLength,
              decoration: InputDecoration(
                hintText: def.format == 'phone'
                    ? '+7 999 123-45-67'
                    : def.format == 'email'
                    ? 'name@example.com'
                    : def.description,
                helperText: def.format == 'phone'
                    ? 'Код страны определяется по международному префиксу'
                    : def.format == 'email'
                    ? 'Например: name@example.com'
                    : null,
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
                  final normalized = def.format == 'phone'
                      ? normalizePhoneNumber(ctrl.text)
                      : ctrl.text.trim();
                  final validation = def.validateInput(
                    normalized,
                    number: number,
                  );
                  if (validation != null) {
                    setLocal(() => error = validation);
                    return;
                  }
                  Navigator.of(ctx).pop(normalized);
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
