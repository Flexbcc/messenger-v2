import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';

/// Responsive body for focused forms such as sign-in, onboarding and pairing.
///
/// It remains vertically scrollable when the software keyboard is visible and
/// keeps controls at a readable width on desktop without special-case layouts
/// in every screen.
class AppFormBody extends StatelessWidget {
  const AppFormBody({
    super.key,
    required this.child,
    this.maxWidth = 420,
    this.padding = const EdgeInsets.all(AppSpacing.xl),
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: padding,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight - AppSpacing.xl * 2,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
