import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_tile.dart';
import '../../models/duress_policy.dart';
import '../../services/duress_policy_session.dart';

/// Manual rule editor for the **custom** duress preset.
class DuressRulesEditorScreen extends StatefulWidget {
  const DuressRulesEditorScreen({super.key});

  @override
  State<DuressRulesEditorScreen> createState() => _DuressRulesEditorScreenState();
}

class _DuressRulesEditorScreenState extends State<DuressRulesEditorScreen> {
  late List<DuressRule> _rules;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final data = DuressPolicySession.instance.data;
    _rules = List.from(data?.rules ?? DuressPresets.rulesFor('P2'));
    _loading = false;
  }

  Future<void> _persist() async {
    await DuressPolicySession.instance.setRules(_rules);
    if (mounted) setState(() {});
  }

  Future<void> _editRule(int index) async {
    final updated = await showModalBottomSheet<DuressRule>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _RuleEditorSheet(rule: _rules[index]),
    );
    if (updated == null) return;
    setState(() => _rules[index] = updated);
    await _persist();
  }

  Future<void> _addRule() async {
    const seed = DuressRule(
      trigger: DuressTrigger.decoyPinStreak,
      threshold: 1,
      actions: [
        DuressAction(type: DuressActionType.notifyTrustedChat, uiCode: 20),
      ],
    );
    final created = await showModalBottomSheet<DuressRule>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _RuleEditorSheet(rule: seed),
    );
    if (created == null) return;
    setState(() => _rules.add(created));
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    final colors = context.colors;

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Свои правила'),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: _addRule),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: AppCard(
              child: Text(
                '«Своя» — это не готовый шаблон, а ваш список: при каком событии, '
                'после скольких раз и что делать (уведомить, заблокировать, очистить). '
                'Глобальный канал доставки можно переопределить для каждого правила.',
                style: text.caption,
              ),
            ),
          ),
          if (_rules.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: Text('Правил нет. Нажмите + чтобы добавить.', style: text.caption),
            )
          else
            AppSettingsGroup(
              title: 'Правила (${_rules.length})',
              children: [
                for (var i = 0; i < _rules.length; i++)
                  Dismissible(
                    key: ValueKey('rule-$i-${_rules[i].trigger.wire}-${_rules[i].threshold}'),
                    direction: DismissDirection.endToStart,
                    onDismissed: (_) async {
                      setState(() => _rules.removeAt(i));
                      await _persist();
                    },
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: AppSpacing.lg),
                      color: colors.danger,
                      child: const Icon(Icons.delete_outline, color: Colors.white),
                    ),
                    child: AppTile(
                      leading: Icon(Icons.rule_folder_outlined, color: colors.textSecondary),
                      title: _rules[i].trigger.labelRu,
                      subtitle: _rules[i].summaryRu,
                      trailing: AppTile.chevron(context),
                      onTap: () => _editRule(i),
                      showDivider: i < _rules.length - 1,
                    ),
                  ),
              ],
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addRule,
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _RuleEditorSheet extends StatefulWidget {
  const _RuleEditorSheet({required this.rule});

  final DuressRule rule;

  @override
  State<_RuleEditorSheet> createState() => _RuleEditorSheetState();
}

class _RuleEditorSheetState extends State<_RuleEditorSheet> {
  late DuressTrigger _trigger;
  late int _threshold;
  late int _windowMin;
  late List<String>? _channels;
  late Set<DuressActionType> _actionTypes;

  @override
  void initState() {
    super.initState();
    _trigger = widget.rule.trigger;
    _threshold = widget.rule.threshold;
    _windowMin = (widget.rule.windowSec / 60).round().clamp(1, 1440);
    _channels = widget.rule.channels == null ? null : List.from(widget.rule.channels!);
    _actionTypes = widget.rule.actions.map((a) => a.type).toSet();
  }

  String _channelKey() {
    if (_channels == null) return 'inherit';
    if (_channels!.contains('chat') && _channels!.contains('relay')) return 'both';
    if (_channels!.contains('relay')) return 'relay';
    return 'chat';
  }

  List<DuressAction> _buildActions() {
    final out = <DuressAction>[];
    for (final type in DuressActionType.values) {
      if (!_actionTypes.contains(type) || type == DuressActionType.none) continue;
      out.add(switch (type) {
        DuressActionType.lockPinUi => const DuressAction(type: DuressActionType.lockPinUi, durationSec: 300),
        DuressActionType.lockApp => const DuressAction(type: DuressActionType.lockApp, durationSec: 300),
        DuressActionType.notifyTrustedChat =>
          const DuressAction(type: DuressActionType.notifyTrustedChat, uiCode: 20),
        DuressActionType.relayEvent => const DuressAction(type: DuressActionType.relayEvent, relayEvent: 20),
        _ => DuressAction(type: type),
      });
    }
    return out.isEmpty ? [const DuressAction(type: DuressActionType.none)] : out;
  }

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;

    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.screenPadding,
        right: AppSpacing.screenPadding,
        bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpacing.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Правило', style: text.title),
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<DuressTrigger>(
              value: _trigger,
              decoration: const InputDecoration(labelText: 'Событие'),
              items: [
                for (final t in DuressTriggerJson.editable)
                  DropdownMenuItem(value: t, child: Text(t.labelRu)),
              ],
              onChanged: (v) => setState(() => _trigger = v ?? _trigger),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextFormField(
              initialValue: '$_threshold',
              decoration: const InputDecoration(labelText: 'Порог (сколько раз)'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (v) => _threshold = int.tryParse(v) ?? 1,
            ),
            const SizedBox(height: AppSpacing.sm),
            TextFormField(
              initialValue: '$_windowMin',
              decoration: const InputDecoration(labelText: 'Окно подсчёта (минуты)'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (v) => _windowMin = int.tryParse(v) ?? 60,
            ),
            const SizedBox(height: AppSpacing.sm),
            DropdownButtonFormField<String>(
              value: _channelKey(),
              decoration: const InputDecoration(labelText: 'Канал доставки'),
              items: const [
                DropdownMenuItem(value: 'inherit', child: Text('Как в общих настройках')),
                DropdownMenuItem(value: 'chat', child: Text('Только чат (E2E)')),
                DropdownMenuItem(value: 'relay', child: Text('Только сервер (relay)')),
                DropdownMenuItem(value: 'both', child: Text('Оба канала')),
              ],
              onChanged: (v) => setState(() {
                _channels = switch (v) {
                  'chat' => List.from(DuressTrustedChannels.chatOnly),
                  'relay' => List.from(DuressTrustedChannels.relayOnly),
                  'both' => List.from(DuressTrustedChannels.both),
                  _ => null,
                };
              }),
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Действия', style: text.subtitle),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final type in DuressActionType.values)
                  if (type != DuressActionType.none)
                    FilterChip(
                      label: Text(type.labelRu),
                      selected: _actionTypes.contains(type),
                      onSelected: (on) => setState(() {
                        if (on) {
                          _actionTypes.add(type);
                        } else {
                          _actionTypes.remove(type);
                        }
                      }),
                    ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed: () {
                Navigator.pop(
                  context,
                  DuressRule(
                    trigger: _trigger,
                    threshold: _threshold.clamp(1, 99),
                    windowSec: _windowMin.clamp(1, 1440) * 60,
                    channels: _channels,
                    actions: _buildActions(),
                  ),
                );
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
  }
}
