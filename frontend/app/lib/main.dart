import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/call_screen.dart';
import 'screens/home_shell.dart';
import 'screens/security/login_approval_waiting_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/bootstrap_service.dart';
import 'services/app_lock_service.dart';
import 'services/database_init.dart';
import 'services/message_format_prefs.dart';
import 'services/os_notification_service.dart';
import 'services/settings_runtime.dart';
import 'state/app_controller.dart';
import 'state/notification_settings.dart';
import 'state/settings_catalog_controller.dart';
import 'state/theme_settings.dart';
import '../core/theme/app_theme.dart';
import 'widgets/app_lock_overlay.dart';
import 'widgets/call_minimized_bar.dart';
import 'widgets/call_stage.dart';
import 'widgets/dev_screen_capture_host.dart';
import 'widgets/in_app_notification_host.dart';
import 'widgets/settings_appearance_wrapper.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: MessengerApp()));
}

/// Locale from catalog `profile.language` — applied on [MaterialApp], never via
/// [Localizations.override] in builder (that strips MaterialLocalizations).
final appLocaleProvider = FutureProvider<Locale>((ref) async {
  ref.watch(settingsCatalogValuesProvider);
  final code = await SettingsRuntime.instance.language();
  return Locale(code == 'en' ? 'en' : 'ru');
});

class MessengerApp extends ConsumerStatefulWidget {
  const MessengerApp({super.key});

  @override
  ConsumerState<MessengerApp> createState() => _MessengerAppState();
}

class _MessengerAppState extends ConsumerState<MessengerApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(() async {
      final controller = ref.read(appControllerProvider);
      try {
        await DatabaseInit.ensureInitialized();
        await BootstrapStore.load();
        try {
          await OsNotificationService.instance.init();
        } catch (_) {}
        try {
          await AppLockService.instance.init();
        } catch (_) {}
        try {
          await bootstrapSettingsCatalog(ref.read)
              .timeout(const Duration(seconds: 12));
        } catch (e) {
          debugPrint('settings catalog bootstrap skipped: $e');
        }
        await MessageFormatPrefs.reload();
        controller.notificationSettings = ref.read(notificationSettingsProvider);
        await controller.boot().timeout(const Duration(seconds: 20));
      } catch (e, st) {
        debugPrint('app start failed: $e\n$st');
        controller.booting = false;
        // Theme/locale refresh is handled by providers; avoid protected notifyListeners.
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // On desktop, `inactive` fires when the window loses focus — treat as screen-off
    // only when security.lock_on_screen_off is enabled.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      AppLockService.instance.arm();
    } else if (state == AppLifecycleState.inactive) {
      AppLockService.instance.armForScreenOff();
    } else if (state == AppLifecycleState.resumed) {
      AppLockService.instance.onResume();
      ref.read(appControllerProvider).onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final themeSettings = ref.watch(themeSettingsProvider);
    final locale = ref.watch(appLocaleProvider).valueOrNull ?? const Locale('ru');
    ref.listen(notificationSettingsProvider, (_, next) {
      ref.read(appControllerProvider).notificationSettings = next;
    });
    ref.listen(settingsCatalogValuesProvider, (_, __) {
      MessageFormatPrefs.reload();
    });

    return MaterialApp(
      title: 'Messenger',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeSettings.mode,
      locale: locale,
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: controller.booting
          ? const _SplashScreen()
          : (!controller.isLoggedIn
              ? const OnboardingScreen()
              : (controller.loginApprovalPending
                  ? const LoginApprovalWaitingScreen()
                  : const HomeShell())),
      // Appearance uses MediaQuery.copyWith only (no Localizations.override — that
      // strips MaterialLocalizations and breaks TextField on desktop).
      builder: (context, child) => DevScreenCaptureHost(
        child: SettingsAppearanceWrapper(
          child: AppLockOverlay(
            child: InAppNotificationHost(
              child: Stack(
                children: [
                  if (child != null) child,
                  if (controller.currentCall != null && controller.callUiMinimized) const CallMinimizedBar(),
                  if (controller.currentCall != null && !controller.callUiMinimized) const CallScreen(),
                  if (controller.callEndedPeerLabel != null)
                    CallEndedOverlay(
                      peerName: controller.callEndedPeerLabel!,
                      onDismiss: controller.clearCallEndedOverlay,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Center(
        child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
