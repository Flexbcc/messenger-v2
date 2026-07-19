import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_tile.dart';
import '../../models/duress_policy.dart';
import '../../services/duress_policy_session.dart';
import '../../state/app_controller.dart';
import 'duress_rules_editor_screen.dart' show DuressRecipeBuilderScreen;
import 'trusted_contacts_screen.dart';

/// Protection recipes builder — no rigid presets.
class DuressPolicyScreen extends ConsumerStatefulWidget {
  const DuressPolicyScreen({super.key});

  @override
  ConsumerState<DuressPolicyScreen> createState() => _DuressPolicyScreenState();
}

class _DuressPolicyScreenState extends ConsumerState<DuressPolicyScreen> {
  List<DuressRule> _rules = [];
  List<String> _channels = List.from(DuressTrustedChannels.both);
  List<String> _trusted = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = DuressPolicySession.instance.data;
    if (!mounted) return;
    setState(() {
      _rules = List.from(data?.rules ?? []);
      _channels = List.from(data?.trustedChannels ?? DuressTrustedChannels.both);
      _trusted = List.from(data?.trustedUserIds ?? []);
      _loading = false;
    });
  }

  Future<void> _persistRules(List<DuressRule> rules) async {
    await DuressPolicySession.instance.setRules(rules);
    await _load();
  }

  Future<void> _openBuilder({DuressRule? existing, int? index}) async {
    final result = await Navigator.of(context).push<DuressRule>(
      MaterialPageRoute(
        builder: (_) => DuressRecipeBuilderScreen(initial: existing),
      ),
    );
    if (result == null) return;
    final next = List<DuressRule>.from(_rules);
    if (index != null) {
      next[index] = result;
    } else {
      next.add(result);
    }
    await _persistRules(next);
  }

  Future<void> _addFromCatalog() async {
    final type = await showModalBottomSheet<DuressActionType>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: Text('Что защитить?', style: context.textStyles.title),
            ),
            for (final t in DuressActionTypeJson.catalog)
              ListTile(
                title: Text(t.labelRu),
                subtitle: Text(t.catalogHintRu),
                onTap: () => Navigator.pop(ctx, t),
              ),
          ],
        ),
      ),
    );
    if (type == null || !mounted) return;
    final seed = DuressRecipeBuilderScreen.seedForAction(type);
    final result = await Navigator.of(context).push<DuressRule>(
      MaterialPageRoute(builder: (_) => DuressRecipeBuilderScreen(initial: seed)),
    );
    if (result == null) return;
    await _persistRules([..._rules, result]);
  }

  Future<void> _addTemplatePack() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final id in DuressPresets.legacyIds)
              ListTile(
                title: Text(DuressPresets.label(id)),
                subtitle: Text(DuressPresets.description(id)),
                onTap: () => Navigator.pop(ctx, id),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await DuressPolicySession.instance.appendTemplatePack(picked);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Добавлен набор: ${DuressPresets.label(picked)}')),
    );
  }

  Future<void> _pickChannels() async {
    final options = <List<String>>[
      DuressTrustedChannels.chatOnly,
      DuressTrustedChannels.relayOnly,
      DuressTrustedChannels.both,
    ];
    final picked = await showModalBottomSheet<List<String>>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final ch in options)
              ListTile(
                title: Text(DuressTrustedChannels.label(ch)),
                subtitle: Text(DuressTrustedChannels.description(ch)),
                trailing: _channelsMatch(ch, _channels) ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, ch),
              ),
          ],
        ),
      ),
    );
    if (picked == null || _channelsMatch(picked, _channels)) return;
    await DuressPolicySession.instance.setTrustedChannels(picked);
    setState(() => _channels = List.from(picked));
  }

  bool _channelsMatch(List<String> a, List<String> b) {
    final na = DuressTrustedChannels.normalize(a);
    final nb = DuressTrustedChannels.normalize(b);
    if (na.length != nb.length) return false;
    return na.every(nb.contains);
  }

  Future<void> _testSignal() async {
    final result = await ref.read(appControllerProvider).testDuressDelivery();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
  }

  bool get _needsTrustedBanner {
    final hasNotify = _rules.any(
      (r) => r.actions.any((a) => a.type == DuressActionType.notifyTrustedChat),
    );
    return hasNotify && _trusted.isEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    final colors = context.colors;

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!DuressPolicySession.instance.isUnlocked) {
      return Scaffold(
        appBar: AppBar(title: const Text('Защита')),
        body: const Center(child: Text('Сначала разблокируйте защищённый раздел')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Защита')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addFromCatalog,
        icon: const Icon(Icons.add),
        label: const Text('Действие'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: AppCard(
              child: Text(
                'Собирайте защиту сами: выберите действие, укажите условие '
                '(когда и после скольких раз) и порядок шагов.',
                style: text.caption,
              ),
            ),
          ),
          if (_needsTrustedBanner)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
              child: AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Есть рецепты оповещения, но список доверенных пуст — '
                      'сигналы пока никуда не уйдут.',
                      style: text.caption.copyWith(color: colors.danger),
                    ),
                    TextButton(
                      onPressed: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const TrustedContactsScreen()),
                        );
                        await _load();
                      },
                      child: const Text('Добавить доверенных'),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.md),
          if (_rules.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: Text(
                'Рецептов нет. Нажмите «Действие» — например, оповестить доверенных при 5× доп. PIN.',
                style: text.caption,
              ),
            )
          else
            AppSettingsGroup(
              title: 'Рецепты (${_rules.length})',
              children: [
                for (var i = 0; i < _rules.length; i++)
                  Dismissible(
                    key: ValueKey('recipe-$i-${_rules[i].trigger.wire}-${_rules[i].threshold}-${_rules[i].actions.length}'),
                    direction: DismissDirection.endToStart,
                    onDismissed: (_) async {
                      final next = List<DuressRule>.from(_rules)..removeAt(i);
                      await _persistRules(next);
                    },
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: AppSpacing.lg),
                      color: colors.danger,
                      child: const Icon(Icons.delete_outline, color: Colors.white),
                    ),
                    child: AppTile(
                      leading: Icon(Icons.shield_outlined, color: colors.textSecondary),
                      title: _rules[i].trigger.labelRu,
                      subtitle: _rules[i].summaryRu,
                      trailing: AppTile.chevron(context),
                      onTap: () => _openBuilder(existing: _rules[i], index: i),
                      showDivider: i < _rules.length - 1,
                    ),
                  ),
              ],
            ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Быстро добавить набор',
            children: [
              AppTile(
                leading: Icon(Icons.library_add_outlined, color: colors.textSecondary),
                title: 'Шаблон рецептов',
                subtitle: 'Дополнит список, не заменит',
                trailing: AppTile.chevron(context),
                onTap: _addTemplatePack,
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Доставка',
            children: [
              AppTile(
                leading: Icon(Icons.hub_outlined, color: colors.textSecondary),
                title: DuressTrustedChannels.label(_channels),
                subtitle: DuressTrustedChannels.description(_channels),
                trailing: AppTile.chevron(context),
                onTap: _pickChannels,
              ),
              AppTile(
                leading: Icon(Icons.verified_user_outlined, color: colors.textSecondary),
                title: 'Доверенные контакты',
                subtitle: '${_trusted.length} выбрано',
                trailing: AppTile.chevron(context),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TrustedContactsScreen()),
                  );
                  await _load();
                },
              ),
              AppTile(
                leading: Icon(Icons.send_outlined, color: colors.textSecondary),
                title: 'Тест доставки',
                subtitle: 'Код 90 — проверить, что сигнал доходит',
                trailing: AppTile.chevron(context),
                onTap: _testSignal,
                showDivider: false,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
