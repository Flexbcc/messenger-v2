import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/settings_runtime.dart';
import '../state/settings_catalog_controller.dart';

/// Applies catalog appearance settings (text scale, animations, compact) to the app tree.
///
/// Safe for [MaterialApp.builder]: only [MediaQuery.copyWith] + [Theme] — never
/// [Localizations.override] (that strips MaterialLocalizations and breaks TextFields).
class SettingsAppearanceWrapper extends ConsumerStatefulWidget {
  const SettingsAppearanceWrapper({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SettingsAppearanceWrapper> createState() =>
      _SettingsAppearanceWrapperState();
}

class _SettingsAppearanceWrapperState
    extends ConsumerState<SettingsAppearanceWrapper> {
  double _textScale = 1.0;
  bool _reduceMotion = false;
  bool _compact = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_reload);
  }

  Future<void> _reload() async {
    final runtime = SettingsRuntime.instance;
    final scale = await runtime.textScaleFactor();
    final reduce =
        await runtime.reduceMotion() || !await runtime.animationsEnabled();
    final compact = await runtime.compactMode();
    if (!mounted) return;
    setState(() {
      _textScale = scale;
      _reduceMotion = reduce;
      _compact = compact;
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(settingsCatalogValuesProvider, (_, __) => _reload());

    final base = Theme.of(context);
    final themed = base.copyWith(
      visualDensity: _compact ? VisualDensity.compact : VisualDensity.standard,
      listTileTheme: base.listTileTheme.copyWith(
        dense: _compact,
        visualDensity: _compact
            ? VisualDensity.compact
            : VisualDensity.standard,
        minVerticalPadding: _compact ? 4 : null,
      ),
    );

    return Theme(
      data: themed,
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(_textScale),
          disableAnimations: _reduceMotion,
        ),
        child: widget.child,
      ),
    );
  }
}
