/// UI/UX migration plan — executed incrementally, no big-bang rewrite.
///
/// ## Audit summary (103 Dart files in lib/)
///
/// **Structure:** screens/ (35), widgets/ (13), state/ (3), theme/ (5), services/ (20),
/// models/ (5), crypto/, calls/, security/, utils/.
///
/// **Navigation:** imperative MaterialPageRoute — no go_router. Entry: main.dart →
/// Onboarding | HomeShell (4 tabs). Private Mode: nested Navigator in private_mode_entry.dart.
///
/// **State:** Riverpod ChangeNotifier — AppController (global), theme/notification settings,
/// PrivateModeState (isolated ProviderScope).
///
/// **Duplicates:** _QuickAction (profile/contacts), label/value rows (3 screens),
/// PIN logic (3 screens), chevron icons inline.
///
/// ## Migration phases
///
/// 1. [done] lib/core/theme — tokens, ThemeExtension, AppTheme
/// 2. [done] lib/core/ui — shared components
/// 3. [in progress] Main tabs + settings via core/ui
/// 4. Chat UX — grouping, status, typing, motion
/// 5. Private Mode — PrivateHomeScreen hub
/// 6. Security stubs — dashboard, verify, recovery, log
/// 7. Web — conditional imports, disabled fallbacks
/// 8. Motion polish — page transitions, press scale
///
/// **Rules:** no API changes, no backend changes, colors/spacing only via tokens.
library;
