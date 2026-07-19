import 'package:flutter/material.dart';

import '../../models/duress_policy.dart';
import '../../theme/app_decorations.dart';
import '../../theme/spacing.dart';
import '../../theme/typography.dart';

/// Centered in-chat banner for `system: duress` messages.
class DuressSignalBanner extends StatelessWidget {
  const DuressSignalBanner({
    super.key,
    required this.code,
    this.text,
  });

  final int code;
  final String? text;

  bool get _isAlert => code >= 30;

  @override
  Widget build(BuildContext context) {
    final label = text ?? DuressSignalLabels.forCode(code);
    final color = _isAlert ? AppColors.dangerRed : AppColors.warningYellow;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.smallGap, horizontal: AppSpacing.screenPadding),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadii.medium),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_isAlert ? Icons.warning_amber_rounded : Icons.info_outline, size: 14, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: AppTypography.caption.copyWith(
                    color: _isAlert ? AppColors.dangerRed : AppColors.textSecondary,
                    fontSize: 11,
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

/// Maps legacy system kinds to numeric codes.
int? duressCodeFromLegacyKind(String? systemKind) => switch (systemKind) {
      'pin_duress_hint' => 20,
      'pin_duress_alert' => 30,
      'duress' => null,
      _ => null,
    };
