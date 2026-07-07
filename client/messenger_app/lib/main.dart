import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/call_screen.dart';
import 'screens/home_shell.dart';
import 'screens/security/login_approval_waiting_screen.dart';
import 'screens/join_network_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/bootstrap_service.dart';
import 'services/app_lock_service.dart';
import 'services/database_init.dart';
import 'services/os_notification_service.dart';
import 'state/app_controller.dart';
import 'state/notification_settings.dart';
import 'state/theme_settings.dart';
import '../core/theme/app_theme.dart';
import 'widgets/app_lock_overlay.dart';
import 'widgets/call_minimized_bar.dart';
import 'widgets/in_app_notification_host.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: MessengerApp()));
}

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
      await DatabaseInit.ensureInitialized();
      await BootstrapStore.load();
      await OsNotificationService.instance.init();
      await AppLockService.instance.init();
      final controller = ref.read(appControllerProvider);
      controller.notificationSettings = ref.read(notificationSettingsProvider);
      await controller.boot();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // On desktop, `inactive` fires when the window loses focus — don't treat that as background.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      AppLockService.instance.arm();
    } else if (state == AppLifecycleState.resumed) {
      AppLockService.instance.onResume();
      ref.read(appControllerProvider).onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final themeSettings = ref.watch(themeSettingsProvider);
    ref.listen(notificationSettingsProvider, (_, next) {
      ref.read(appControllerProvider).notificationSettings = next;
    });

    return MaterialApp(
      title: 'Messenger',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeSettings.mode,
      home: controller.booting
          ? const _SplashScreen()
          : (!controller.isLoggedIn
              ? const OnboardingScreen()
              : (controller.loginApprovalPending
                  ? const LoginApprovalWaitingScreen()
                  : const HomeShell())),
      builder: (context, child) => AppLockOverlay(
        child: InAppNotificationHost(
          child: Stack(
            children: [
              if (child != null) child,
              if (controller.currentCall != null && controller.callUiMinimized) const CallMinimizedBar(),
              if (controller.currentCall != null && !controller.callUiMinimized) const CallScreen(),
            ],
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
