import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_button.dart';
import '../core/ui/app_card.dart';
import '../services/catalog_seed_service.dart';
import '../state/settings_catalog_controller.dart';

/// Raw JSON view of all catalog values — for dev/testing.
class SettingsCatalogJsonScreen extends ConsumerStatefulWidget {
  const SettingsCatalogJsonScreen({super.key});

  @override
  ConsumerState<SettingsCatalogJsonScreen> createState() =>
      _SettingsCatalogJsonScreenState();
}

class _SettingsCatalogJsonScreenState
    extends ConsumerState<SettingsCatalogJsonScreen> {
  String _json = '';
  bool _loading = true;
  String? _status;

  @override
  void initState() {
    super.initState();
    Future.microtask(_refresh);
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _status = null;
    });
    try {
      final catalog = await ref.read(settingsCatalogProvider.future);
      final seed = CatalogSeedService();
      final blob = await seed.exportJson(catalog);
      if (!mounted) return;
      setState(() {
        _json = const JsonEncoder.withIndent('  ').convert(blob);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _json = '';
        _loading = false;
        _status = 'Ошибка: $e';
      });
    }
  }

  Future<void> _applyDevSeed() async {
    setState(() => _status = 'Заполняем…');
    try {
      final catalog = await ref.read(settingsCatalogProvider.future);
      final n = await CatalogSeedService().applyDevSeedAsset(catalog);
      await ref.read(settingsCatalogValuesProvider).reloadFromLegacy(catalog);
      if (!mounted) return;
      setState(
        () => _status = 'Применено $n значений из dev-catalog-seed.json',
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Ошибка: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    final colors = context.colors;

    return Scaffold(
      appBar: AppBar(
        title: const Text('JSON настроек'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Копировать',
            onPressed: _json.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: _json));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('JSON скопирован')),
                    );
                  },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
            onPressed: _refresh,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Хранение: SharedPreferences (не SQL). Ключи вида '
                    'app_settings_catalog.profile.display_name. '
                    'Здесь — один JSON-снимок со snake_case ключами '
                    '(profile_display_name = "kekwekke").',
                    style: text.caption,
                  ),
                  if (_status != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      _status!,
                      style: text.caption.copyWith(color: colors.primary),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  AppButton(
                    label: 'Заполнить тестовыми данными',
                    icon: Icons.science_outlined,
                    onPressed: _applyDevSeed,
                  ),
                ],
              ),
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_json.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: Text('Нет данных', style: text.body),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenPadding,
              ),
              child: SelectableText(
                _json,
                style: text.caption.copyWith(
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
