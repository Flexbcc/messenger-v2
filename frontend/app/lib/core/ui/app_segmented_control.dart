import 'package:flutter/material.dart';

import '../extensions/context_extensions.dart';
import '../theme/app_motion.dart';
import '../theme/app_radius.dart';

/// Two-or-more segment picker (e.g. All / Missed calls).
class AppSegmentedControl extends StatelessWidget {
  const AppSegmentedControl({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return Container(
      height: 36,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colors.cardSoft,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(i),
                child: AnimatedContainer(
                  duration: AppMotion.fast,
                  curve: AppMotion.standard,
                  decoration: BoxDecoration(
                    color: i == selectedIndex ? colors.card : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.sm - 2),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    labels[i],
                    style: text.subtitle.copyWith(
                      fontSize: 13,
                      color: i == selectedIndex ? colors.textPrimary : colors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
