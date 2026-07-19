import 'package:flutter/material.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_card.dart';
import '../../models/duress_policy.dart';
import '../../services/duress_policy_session.dart';
import '../../services/duress_runtime_store.dart';

/// Human-readable summary of protection recipes for a trigger.
class DuressBehaviorCard extends StatelessWidget {
  const DuressBehaviorCard({
    super.key,
    required this.title,
    required this.trigger,
  });

  final String title;
  final DuressTrigger trigger;

  List<DuressRule> _rules() {
    final data = DuressPolicySession.instance.data;
    if (data != null) {
      return data.rules.where((r) => r.trigger == trigger).toList();
    }
    // Mirror / seed when vault locked
    return DuressPresets.defaultSeedRules.where((r) => r.trigger == trigger).toList();
  }

  String _actionLabel(DuressAction a) {
    final base = a.type.labelRu;
    if (a.type == DuressActionType.lockPinUi || a.type == DuressActionType.lockApp) {
      final sec = a.durationSec;
      if (sec != null && sec > 0) return '$base (${sec} сек)';
    }
    if (a.type == DuressActionType.notifyTrustedChat &&
        a.messageTemplate != null &&
        a.messageTemplate!.trim().isNotEmpty) {
      final t = a.messageTemplate!.trim();
      return t.length > 48 ? '${t.substring(0, 48)}…' : t;
    }
    return base;
  }

  String _ruleLine(DuressRule r) {
    final when = r.threshold <= 1 ? 'Сразу' : 'После ${r.threshold}×';
    final windowMin = (r.windowSec / 60).round();
    final window = windowMin > 0 ? ' за $windowMin мин' : '';
    final actions = r.actions.map(_actionLabel).join(' → ');
    return '$when$window → $actions';
  }

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    final colors = context.colors;
    final rules = _rules();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: text.sectionTitle),
            const SizedBox(height: 4),
            Text(
              'Настраивается в разделе «Защита» — действие + условие + очередь',
              style: text.caption.copyWith(color: colors.textMuted),
            ),
            const SizedBox(height: AppSpacing.sm),
            if (rules.isEmpty)
              Text('Нет рецептов для этого события', style: text.caption)
            else
              for (final r in rules)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.circle, size: 6, color: colors.primary),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_ruleLine(r), style: text.body)),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

/// Load runtime mirror so summaries work before vault unlock.
Future<void> warmDuressMirror() async {
  if (DuressPolicySession.instance.isUnlocked) return;
  await DuressRuntimeStore.instance.loadMirror();
}
