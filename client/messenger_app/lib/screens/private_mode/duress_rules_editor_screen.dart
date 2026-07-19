import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_card.dart';
import '../../models/conversation.dart';
import '../../models/duress_policy.dart';
import '../../state/app_controller.dart';

/// Wizard: configure condition + ordered actions for one protection recipe.
class DuressRecipeBuilderScreen extends ConsumerStatefulWidget {
  const DuressRecipeBuilderScreen({super.key, this.initial});

  final DuressRule? initial;

  static DuressRule seedForAction(DuressActionType type) {
    final action = switch (type) {
      DuressActionType.notifyTrustedChat => const DuressAction(
          type: DuressActionType.notifyTrustedChat,
          uiCode: 30,
          messageTemplate: DuressAction.defaultDangerTemplate,
        ),
      DuressActionType.relayEvent => const DuressAction(type: DuressActionType.relayEvent, relayEvent: 30),
      DuressActionType.lockPinUi => const DuressAction(type: DuressActionType.lockPinUi, durationSec: 300),
      DuressActionType.lockApp => const DuressAction(type: DuressActionType.lockApp, durationSec: 300),
      DuressActionType.deleteChats => const DuressAction(
          type: DuressActionType.deleteChats,
          chatScope: DuressChatScope.allHidden,
          chatDeleteMode: DuressChatDeleteMode.clearHistory,
        ),
      DuressActionType.showDecoyOnly => const DuressAction(type: DuressActionType.showDecoyOnly),
      DuressActionType.purgeSecretMessages => const DuressAction(type: DuressActionType.purgeSecretMessages),
      DuressActionType.wipePrivateVault => const DuressAction(type: DuressActionType.wipePrivateVault),
      DuressActionType.deactivateSecretSessions =>
        const DuressAction(type: DuressActionType.deactivateSecretSessions),
      DuressActionType.none => const DuressAction(type: DuressActionType.none),
    };
    final trigger = type == DuressActionType.showDecoyOnly || type == DuressActionType.notifyTrustedChat
        ? DuressTrigger.decoyPinStreak
        : DuressTrigger.pinUnlockFail;
    final threshold = type == DuressActionType.notifyTrustedChat ? 5 : 3;
    return DuressRule(
      trigger: trigger,
      threshold: threshold,
      windowSec: 86400,
      actions: [action],
    );
  }

  @override
  ConsumerState<DuressRecipeBuilderScreen> createState() => _DuressRecipeBuilderScreenState();
}

class _DuressRecipeBuilderScreenState extends ConsumerState<DuressRecipeBuilderScreen> {
  late DuressTrigger _trigger;
  late int _threshold;
  late int _windowMin;
  late List<String>? _channels;
  late List<DuressAction> _actions;

  @override
  void initState() {
    super.initState();
    final r = widget.initial ??
        const DuressRule(
          trigger: DuressTrigger.decoyPinStreak,
          threshold: 5,
          actions: [
            DuressAction(
              type: DuressActionType.notifyTrustedChat,
              uiCode: 30,
              messageTemplate: DuressAction.defaultDangerTemplate,
            ),
          ],
        );
    _trigger = r.trigger;
    _threshold = r.threshold;
    _windowMin = (r.windowSec / 60).round().clamp(1, 1440);
    _channels = r.channels == null ? null : List.from(r.channels!);
    _actions = List.from(r.actions);
  }

  String _channelKey() {
    if (_channels == null) return 'inherit';
    if (_channels!.contains('chat') && _channels!.contains('relay')) return 'both';
    if (_channels!.contains('relay')) return 'relay';
    return 'chat';
  }

  Future<void> _editAction(int index) async {
    final controller = ref.read(appControllerProvider);
    final updated = await showModalBottomSheet<DuressAction>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _ActionParamsSheet(
        action: _actions[index],
        conversations: controller.conversations,
        titleFor: controller.conversationTitle,
      ),
    );
    if (updated == null) return;
    setState(() => _actions[index] = updated);
  }

  Future<void> _addAction() async {
    final type = await showModalBottomSheet<DuressActionType>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final t in DuressActionTypeJson.catalog)
              ListTile(
                title: Text(t.labelRu),
                onTap: () => Navigator.pop(ctx, t),
              ),
          ],
        ),
      ),
    );
    if (type == null || !mounted) return;
    final seed = DuressRecipeBuilderScreen.seedForAction(type).actions.first;
    final controller = ref.read(appControllerProvider);
    final updated = await showModalBottomSheet<DuressAction>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _ActionParamsSheet(
        action: seed,
        conversations: controller.conversations,
        titleFor: controller.conversationTitle,
      ),
    );
    if (updated == null) return;
    setState(() => _actions.add(updated));
  }

  void _save() {
    if (_actions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Добавьте хотя бы одно действие')),
      );
      return;
    }
    Navigator.pop(
      context,
      DuressRule(
        trigger: _trigger,
        threshold: _threshold.clamp(1, 99),
        windowSec: _windowMin.clamp(1, 1440) * 60,
        channels: _channels,
        actions: List.from(_actions),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    final colors = context.colors;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Рецепт защиты'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Сохранить')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: AppCard(
              child: Text(
                '1) Когда срабатывать  2) Какие действия и в каком порядке',
                style: text.caption,
              ),
            ),
          ),
          AppSettingsGroup(
            title: 'Условие',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: DropdownButtonFormField<DuressTrigger>(
                  value: _trigger,
                  decoration: const InputDecoration(labelText: 'Событие'),
                  items: [
                    for (final t in DuressTriggerJson.editable)
                      DropdownMenuItem(value: t, child: Text(t.labelRu)),
                  ],
                  onChanged: (v) => setState(() => _trigger = v ?? _trigger),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: TextFormField(
                  initialValue: '$_threshold',
                  decoration: const InputDecoration(labelText: 'После скольких раз'),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (v) => _threshold = int.tryParse(v) ?? 1,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: TextFormField(
                  initialValue: '$_windowMin',
                  decoration: const InputDecoration(labelText: 'Окно подсчёта (минуты)'),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (v) => _windowMin = int.tryParse(v) ?? 60,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: DropdownButtonFormField<String>(
                  value: _channelKey(),
                  decoration: const InputDecoration(labelText: 'Канал оповещений'),
                  items: const [
                    DropdownMenuItem(value: 'inherit', child: Text('Как в общих настройках')),
                    DropdownMenuItem(value: 'chat', child: Text('Только чат (E2E)')),
                    DropdownMenuItem(value: 'relay', child: Text('Только сервер')),
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
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
            child: Row(
              children: [
                Expanded(child: Text('Очередь действий', style: text.sectionTitle)),
                TextButton.icon(
                  onPressed: _addAction,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Шаг'),
                ),
              ],
            ),
          ),
          if (_actions.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: Text('Пока пусто — добавьте шаг', style: text.caption),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _actions.length,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (newIndex > oldIndex) newIndex -= 1;
                  final item = _actions.removeAt(oldIndex);
                  _actions.insert(newIndex, item);
                });
              },
              itemBuilder: (context, index) {
                final a = _actions[index];
                return ListTile(
                  key: ValueKey('action-$index-${a.type.wire}'),
                  leading: Icon(Icons.drag_handle, color: colors.textMuted),
                  title: Text('${index + 1}. ${a.type.labelRu}'),
                  subtitle: Text(_actionSubtitle(a)),
                  trailing: IconButton(
                    icon: Icon(Icons.delete_outline, color: colors.danger),
                    onPressed: () => setState(() => _actions.removeAt(index)),
                  ),
                  onTap: () => _editAction(index),
                );
              },
            ),
        ],
      ),
    );
  }

  String _actionSubtitle(DuressAction a) {
    switch (a.type) {
      case DuressActionType.notifyTrustedChat:
        final t = a.messageTemplate?.trim();
        if (t != null && t.isNotEmpty) {
          return t.length > 60 ? '${t.substring(0, 60)}…' : t;
        }
        return 'Код ${a.uiCode ?? 30}';
      case DuressActionType.relayEvent:
        return 'Код ${a.relayEvent ?? 30}';
      case DuressActionType.lockPinUi:
      case DuressActionType.lockApp:
        return '${a.durationSec ?? 300} сек';
      case DuressActionType.deleteChats:
        final scope = a.chatScope?.labelRu ?? 'чаты';
        final mode = a.chatDeleteMode?.labelRu ?? '';
        return '$scope · $mode';
      default:
        return a.type.catalogHintRu;
    }
  }
}

class _ActionParamsSheet extends StatefulWidget {
  const _ActionParamsSheet({
    required this.action,
    required this.conversations,
    required this.titleFor,
  });

  final DuressAction action;
  final List<Conversation> conversations;
  final String Function(Conversation) titleFor;

  @override
  State<_ActionParamsSheet> createState() => _ActionParamsSheetState();
}

class _ActionParamsSheetState extends State<_ActionParamsSheet> {
  late DuressAction _action;
  late TextEditingController _templateCtrl;
  late TextEditingController _durationCtrl;
  late TextEditingController _codeCtrl;

  @override
  void initState() {
    super.initState();
    _action = widget.action;
    _templateCtrl = TextEditingController(
      text: _action.messageTemplate ?? DuressAction.defaultDangerTemplate,
    );
    _durationCtrl = TextEditingController(text: '${_action.durationSec ?? 300}');
    _codeCtrl = TextEditingController(
      text: '${_action.uiCode ?? _action.relayEvent ?? 30}',
    );
  }

  @override
  void dispose() {
    _templateCtrl.dispose();
    _durationCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    final convs = widget.conversations;

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
            Text(_action.type.labelRu, style: text.title),
            const SizedBox(height: AppSpacing.sm),
            Text(_action.type.catalogHintRu, style: text.caption),
            const SizedBox(height: AppSpacing.md),
            if (_action.type == DuressActionType.notifyTrustedChat) ...[
              TextField(
                controller: _templateCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Текст в чате доверенным',
                  helperText: '{name} — имя, {threshold} — порог',
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _codeCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'UI / severity код (10–90)'),
              ),
            ],
            if (_action.type == DuressActionType.relayEvent)
              TextField(
                controller: _codeCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Код relay (сервер видит только число)'),
              ),
            if (_action.type == DuressActionType.lockPinUi || _action.type == DuressActionType.lockApp)
              TextField(
                controller: _durationCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Длительность (сек)'),
              ),
            if (_action.type == DuressActionType.deleteChats) ...[
              DropdownButtonFormField<DuressChatScope>(
                value: _action.chatScope ?? DuressChatScope.allHidden,
                decoration: const InputDecoration(labelText: 'Какие чаты'),
                items: [
                  for (final s in DuressChatScope.values)
                    DropdownMenuItem(value: s, child: Text(s.labelRu)),
                ],
                onChanged: (v) => setState(() {
                  _action = _action.copyWith(chatScope: v);
                }),
              ),
              const SizedBox(height: AppSpacing.sm),
              DropdownButtonFormField<DuressChatDeleteMode>(
                value: _action.chatDeleteMode ?? DuressChatDeleteMode.clearHistory,
                decoration: const InputDecoration(labelText: 'Что сделать'),
                items: [
                  for (final m in DuressChatDeleteMode.values)
                    DropdownMenuItem(value: m, child: Text(m.labelRu)),
                ],
                onChanged: (v) => setState(() {
                  _action = _action.copyWith(chatDeleteMode: v);
                }),
              ),
              if ((_action.chatScope ?? DuressChatScope.specific) == DuressChatScope.specific) ...[
                const SizedBox(height: AppSpacing.sm),
                Text('Выберите чаты', style: text.caption),
                ...convs.take(40).map((c) {
                  final selected = _action.conversationIds?.contains(c.id) ?? false;
                  return CheckboxListTile(
                    dense: true,
                    value: selected,
                    title: Text(widget.titleFor(c)),
                    onChanged: (on) {
                      final ids = List<String>.from(_action.conversationIds ?? []);
                      if (on == true) {
                        if (!ids.contains(c.id)) ids.add(c.id);
                      } else {
                        ids.remove(c.id);
                      }
                      setState(() => _action = _action.copyWith(conversationIds: ids));
                    },
                  );
                }),
              ],
            ],
            if (_action.type == DuressActionType.wipePrivateVault)
              Text(
                'Опасно: сотрёт PIN-хранилище Private Mode на этом устройстве.',
                style: text.caption.copyWith(color: context.colors.danger),
              ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed: () {
                var out = _action;
                if (out.type == DuressActionType.notifyTrustedChat) {
                  out = out.copyWith(
                    messageTemplate: _templateCtrl.text.trim(),
                    uiCode: int.tryParse(_codeCtrl.text) ?? 30,
                  );
                } else if (out.type == DuressActionType.relayEvent) {
                  out = out.copyWith(relayEvent: int.tryParse(_codeCtrl.text) ?? 30);
                } else if (out.type == DuressActionType.lockPinUi || out.type == DuressActionType.lockApp) {
                  out = out.copyWith(durationSec: int.tryParse(_durationCtrl.text) ?? 300);
                }
                Navigator.pop(context, out);
              },
              child: const Text('Готово'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the recipe list (policy screen) — kept for old deep links.
class DuressRulesEditorScreen extends StatelessWidget {
  const DuressRulesEditorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const DuressRecipeBuilderScreen();
  }
}
