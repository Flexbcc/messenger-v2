// Private Mode / Secret Room — module entry point.
//
// Integration: Settings → Конфиденциальность → privateModeEntryRoute()

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'panic.dart';
import 'unlock_screen.dart';

export 'panic.dart';

/// Route that opens the whole Private Mode module (starting at the PIN unlock screen).
Route<void> privateModeEntryRoute() {
  return PageRouteBuilder<void>(
    pageBuilder: (context, animation, secondaryAnimation) =>
        const PrivateModeEntry(),
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
  );
}

/// Root widget of the Private Mode module with isolated ProviderScope.
class PrivateModeEntry extends StatelessWidget {
  const PrivateModeEntry({super.key});

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: Navigator(
        onGenerateRoute: (settings) =>
            MaterialPageRoute(builder: (_) => const UnlockScreen()),
      ),
    );
  }
}

/// @deprecated Import [panic.dart] instead.
@Deprecated('Use panic.dart')
void panicExitLegacy(BuildContext context) => panicExit(context);
