import 'package:flutter/material.dart';

import '../extensions/context_extensions.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';

/// Choice / options picker for settings — centered dialog (not a bottom sheet).
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
}) {
  // Legacy name kept for call sites; UI is a centered dialog per product UX.
  return showAppChoiceDialog<T>(context: context, builder: builder);
}

/// Centered options dialog used by settings pickers.
Future<T?> showAppChoiceDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showDialog<T>(
    context: context,
    builder: (ctx) {
      return Dialog(
        backgroundColor: context.colors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: builder(ctx),
          ),
        ),
      );
    },
  );
}

/// Standard action sheet item.
class AppSheetAction extends StatelessWidget {
  const AppSheetAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ListTile(
      leading: Icon(icon, color: danger ? colors.danger : colors.textSecondary),
      title: Text(label, style: TextStyle(color: danger ? colors.danger : colors.textPrimary)),
      onTap: onTap,
    );
  }
}
