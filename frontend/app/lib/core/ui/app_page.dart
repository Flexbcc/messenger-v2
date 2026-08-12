import 'package:flutter/material.dart';

import '../extensions/context_extensions.dart';
import '../theme/app_spacing.dart';

/// Standard scaffold with themed background and optional scroll body.
class AppPage extends StatelessWidget {
  const AppPage({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.padding,
    this.scroll = true,
    required this.child,
  });

  final String? title;
  final List<Widget>? actions;
  final Widget? leading;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final EdgeInsetsGeometry? padding;
  final bool scroll;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final body = Padding(padding: padding ?? EdgeInsets.zero, child: child);

    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: title == null
          ? null
          : AppBar(title: Text(title!), leading: leading, actions: actions),
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
      body: scroll
          ? SafeArea(child: SingleChildScrollView(child: body))
          : SafeArea(child: body),
    );
  }
}

/// List page variant — ListView body with standard padding.
class AppListPage extends StatelessWidget {
  const AppListPage({
    super.key,
    required this.title,
    this.actions,
    this.leading,
    this.children = const [],
    this.bottom,
  });

  final String title;
  final List<Widget>? actions;
  final Widget? leading;
  final List<Widget> children;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(title: Text(title), actions: actions, leading: leading),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: children,
      ),
      bottomNavigationBar: bottom,
    );
  }
}
