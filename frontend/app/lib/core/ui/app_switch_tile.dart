import 'package:flutter/material.dart';

import 'app_tile.dart';

/// Settings row with a switch on the right.
class AppSwitchTile extends StatelessWidget {
  const AppSwitchTile({
    super.key,
    this.leading,
    required this.title,
    this.titleWidget,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.showDivider = false,
    this.enabled = true,
  });

  final Widget? leading;
  final String title;
  final Widget? titleWidget;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool showDivider;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return AppTile(
      leading: leading,
      title: title,
      titleWidget: titleWidget,
      subtitle: subtitle,
      showDivider: showDivider,
      enabled: enabled,
      onTap: enabled ? () => onChanged(!value) : null,
      trailing: Switch.adaptive(
        value: value,
        onChanged: enabled ? onChanged : null,
      ),
    );
  }
}
