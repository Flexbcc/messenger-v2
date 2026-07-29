import 'package:flutter/material.dart';

import '../core/extensions/context_extensions.dart';
import '../models/settings_impl_status.dart';

/// Setting title with a red asterisk when the value is UI-only (not wired).
class SettingTitleLabel extends StatelessWidget {
  const SettingTitleLabel({
    super.key,
    required this.settingId,
    required this.title,
    this.style,
  });

  final String settingId;
  final String title;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    final colors = context.colors;
    final base = style ?? text.subtitle.copyWith(color: colors.textPrimary);
    if (SettingsImplStatus.isLive(settingId)) {
      return Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: base);
    }
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: title, style: base),
          TextSpan(
            text: ' *',
            style: base.copyWith(color: colors.danger, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Legend strip for catalog / settings screens.
class SettingsStubLegend extends StatelessWidget {
  const SettingsStubLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('*', style: text.body.copyWith(color: colors.danger, fontWeight: FontWeight.bold)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '— настройка пока только в интерфейсе (сохраняется локально, на поведение не влияет)',
            style: text.caption.copyWith(color: colors.textMuted),
          ),
        ),
      ],
    );
  }
}
