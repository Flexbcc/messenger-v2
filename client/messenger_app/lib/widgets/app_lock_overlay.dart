import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/duress_policy.dart';
import '../screens/private_mode/fake_mode_screen.dart';
import '../screens/private_mode/pin_keypad.dart';
import '../security/pin_security.dart';
import '../services/app_lock_service.dart';
import '../services/app_privacy_session.dart';
import '../services/duress_policy_engine.dart';
import '../services/duress_policy_session.dart';
import '../services/hidden_vault_session.dart';
import '../services/privacy_preferences_store.dart';
import '../services/settings_catalog_bridge.dart';
import '../state/app_controller.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

/// Full-screen PIN gate when App Lock is enabled and app resumes.
class AppLockOverlay extends ConsumerStatefulWidget {
  const AppLockOverlay({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppLockOverlay> createState() => _AppLockOverlayState();
}

class _AppLockOverlayState extends ConsumerState<AppLockOverlay> with SingleTickerProviderStateMixin {
  final _lock = AppLockService.instance;
  String _input = '';
  String? _error;
  int _wrongAttempts = 0;
  bool _lockedOut = false;
  Duration? _lockoutRemaining;
  Timer? _lockoutTimer;
  late final AnimationController _shakeController;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _lock.addListener(_onLockChanged);
    _refreshLockout();
  }

  @override
  void dispose() {
    _lockoutTimer?.cancel();
    _lock.removeListener(_onLockChanged);
    _shakeController.dispose();
    super.dispose();
  }

  Future<void> _refreshLockout() async {
    final locked = await DuressPolicyEngine.instance.isPinLockedOut();
    final rem = await DuressPolicyEngine.instance.lockoutRemaining();
    if (!mounted) return;
    setState(() {
      _lockedOut = locked;
      _lockoutRemaining = rem;
    });
    _lockoutTimer?.cancel();
    if (locked && rem != null) {
      _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (_) => _refreshLockout());
    }
  }

  String _formatLockout(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _onLockChanged() {
    if (mounted) setState(() {});
  }

  void _onDigit(String d) {
    if (_lockedOut || _input.length >= kPinLength) return;
    setState(() {
      _error = null;
      _input += d;
    });
    if (_input.length == kPinLength) {
      Future.delayed(const Duration(milliseconds: 120), _evaluate);
    }
  }

  void _onBackspace() {
    if (_input.isEmpty || _lockedOut) return;
    setState(() => _input = _input.substring(0, _input.length - 1));
  }

  Future<void> _evaluate() async {
    if (_lockedOut) return;

    final controller = ref.read(appControllerProvider);
    final pin = _input;
    final result = await PinSecurity.evaluatePin(pin);
    if (!mounted) return;

    if (result == PinUnlockResult.fakePin) {
      // Fake PIN: enter decoy mode silently, fire duress trigger, show FakeMode.
      _lock.unlock();
      AppPrivacySession.instance.enterDecoyMode();
      controller.deactivateSecretSessionForAll();
      await controller.reloadFakeProfileChats();
      await DuressPolicyEngine.instance.handle(
        DuressTrigger.decoyPinStreak,
        controller: controller,
      );
      if (!mounted) return;
      HiddenVaultSession.instance.lock();
      DuressPolicySession.instance.lock();
      setState(() {
        _input = '';
        _error = null;
      });
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(builder: (_) => const FakeModeScreen()),
      );
      return;
    }

    if (result == PinUnlockResult.realPin) {
      _lock.unlock();
      _wrongAttempts = 0;
      setState(() {
        _input = '';
        _error = null;
      });
      return;
    }

    // Invalid PIN.
    final prefs = PrivacyPreferencesStore();
    if (await prefs.wipeOnWrongAttempts()) {
      _wrongAttempts++;
      final wipeRaw = await CatalogSettingsReader().getString('security.wipe_after', '15');
      final wipeAfter = int.tryParse(wipeRaw) ?? 15;
      if (_wrongAttempts >= wipeAfter) {
        await PinSecurity.clearAll();
        await HiddenVaultSession.instance.wipe();
        await DuressPolicySession.instance.wipe();
        _wrongAttempts = 0;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Данные Private Mode удалены')),
          );
        }
      }
    }

    final hr = await DuressPolicyEngine.instance.handle(
      DuressTrigger.appLockFail,
      controller: controller,
    );
    await _refreshLockout();
    if (!mounted) return;
    setState(() {
      _error = hr.lockoutUntil != null
          ? 'Подождите ${_formatLockout(hr.lockoutUntil!.difference(DateTime.now()))}'
          : 'Неверный PIN';
      _input = '';
    });
    _shakeController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_lock.isLocked)
          Positioned.fill(
            child: Material(
              color: AppColors.backgroundLight,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
                  child: Column(
                    children: [
                      const SizedBox(height: AppSpacing.sectionGap * 2),
                      const Icon(Icons.lock_outline, size: 40, color: AppColors.textPrimary),
                      const SizedBox(height: AppSpacing.mediumGap),
                      Text('Messenger', style: AppTypography.title),
                      const SizedBox(height: AppSpacing.smallGap),
                      Text('Введите PIN для разблокировки', style: AppTypography.secondary),
                      const Spacer(),
                      if (_lockedOut) ...[
                        Text('Ввод заблокирован', style: AppTypography.secondary),
                        const SizedBox(height: AppSpacing.smallGap),
                        Text(
                          _lockoutRemaining != null ? _formatLockout(_lockoutRemaining!) : '…',
                          style: AppTypography.largeTitle,
                        ),
                      ] else ...[
                        ShakeOnError(
                          controller: _shakeController,
                          child: PinDotsIndicator(filledCount: _input.length),
                        ),
                        const SizedBox(height: AppSpacing.smallGap),
                        SizedBox(
                          height: 20,
                          child: _error != null
                              ? Text(_error!, style: AppTypography.caption.copyWith(color: AppColors.dangerRed))
                              : null,
                        ),
                        const SizedBox(height: AppSpacing.sectionGap),
                        PinKeypad(onDigit: _onDigit, onBackspace: _onBackspace),
                      ],
                      const Spacer(),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
