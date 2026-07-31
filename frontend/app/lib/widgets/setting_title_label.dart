import 'package:flutter/material.dart';

import '../core/extensions/context_extensions.dart';
import '../models/settings_impl_status.dart';

/// Setting title status: no mark = verified, amber dot = wired but not audited,
/// red asterisk = known incomplete/UI-only.
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
    if (SettingsImplStatus.isVerified(settingId)) {
      return Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }
    final incomplete = SettingsImplStatus.isStub(settingId);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: title, style: base),
          TextSpan(
            text: incomplete ? ' *' : ' •',
            style: base.copyWith(
              color: incomplete ? colors.danger : colors.warning,
              fontWeight: FontWeight.bold,
            ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '• — подключена кодом, но ещё не прошла последовательный аудит',
          style: text.caption.copyWith(color: colors.warning),
        ),
        const SizedBox(height: 4),
        Text(
          '* — известна как неполная или пока только сохраняется',
          style: text.caption.copyWith(color: colors.danger),
        ),
      ],
    );
  }
}
