import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/colors.dart';
import '../../theme/spacing.dart';
import '../../theme/typography.dart';
import '../../widgets/app_button.dart';
import '../../services/security_log_service.dart';
import '../../services/hidden_vault_session.dart';
import '../../services/app_privacy_session.dart';
import '../../services/duress_policy_engine.dart';
import '../../services/duress_policy_session.dart';
import '../../services/privacy_preferences_store.dart';
import '../../security/pin_security.dart';
import '../../models/duress_policy.dart';
import 'fake_mode_screen.dart';
import 'pin_keypad.dart';
import 'pin_setup_screen.dart';
import 'private_mode_state.dart';
import 'private_home_screen.dart';
import '../../state/app_controller.dart';

/// PIN entry screen for the Private Mode module.
class UnlockScreen extends ConsumerStatefulWidget {
  const UnlockScreen({super.key});

  @override
  ConsumerState<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<UnlockScreen> with SingleTickerProviderStateMixin {
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
    _refreshLockout();
  }

  @override
  void dispose() {
    _lockoutTimer?.cancel();
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

    final pm = ref.read(privateModeStateProvider);
    final prefs = PrivacyPreferencesStore();
    final controller = ref.read(appControllerProvider);
    final pin = _input;
    final result = await pm.evaluate(pin);
    if (!mounted) return;

    if (result == UnlockResult.invalid) {
      if (await prefs.wipeOnWrongAttempts()) {
        _wrongAttempts++;
        if (_wrongAttempts >= 5) {
          await pm.reset();
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
        DuressTrigger.pinUnlockFail,
        controller: controller,
      );
      await _refreshLockout();
      if (!mounted) return;
      setState(() {
        _error = hr.lockoutUntil != null
            ? 'Слишком много попыток. Подождите ${_formatLockout(hr.lockoutUntil!.difference(DateTime.now()))}'
            : 'Неверный PIN';
        _input = '';
      });
      _shakeController.forward(from: 0);
      return;
    }

    if (result == UnlockResult.fakePin) {
      if (!await PinSecurity.hasFakePin()) {
        await DuressPolicyEngine.instance.handle(DuressTrigger.pinUnlockFail, controller: controller);
        setState(() {
          _error = 'Неверный PIN';
          _input = '';
        });
        _shakeController.forward(from: 0);
        return;
      }
      AppPrivacySession.instance.enterDecoyMode();
      controller.deactivateSecretSessionForAll();
      await DuressPolicyEngine.instance.handle(DuressTrigger.decoyPinStreak, controller: controller);
      if (!mounted) return;
      _openFakeMode();
      return;
    }

    await DuressPolicyEngine.instance.handle(
      DuressTrigger.pinUnlockOkReal,
      controller: controller,
      incrementCounter: false,
    );
    await DuressPolicySession.instance.unlock(pin);
    AppPrivacySession.instance.enterPrivateMode();

    final secretEnabled = await prefs.secretRoomEnabled();
    if (!secretEnabled) {
      setState(() {
        _error = 'Private Mode отключён в настройках';
        _input = '';
      });
      return;
    }
    final vaultOk = await HiddenVaultSession.instance.unlock(pin);
    if (!mounted) return;
    if (!vaultOk) {
      setState(() {
        _error = 'Не удалось открыть хранилище';
        _input = '';
      });
      _shakeController.forward(from: 0);
      return;
    }
    _openSecretRoom();
  }

  void _openSecretRoom() {
    AppPrivacySession.instance.enterPrivateMode();
    SecurityLogService.instance.append(
      SecurityEvent(title: 'Secret Room открыт', subtitle: 'Успешный PIN', at: DateTime.now(), icon: 'room'),
    );
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const PrivateHomeScreen()));
  }

  void _openFakeMode() {
    HiddenVaultSession.instance.lock();
    DuressPolicySession.instance.lock();
    AppPrivacySession.instance.enterDecoyMode();
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const FakeModeScreen()));
  }

  void _onBiometricTap() async {
    if (!ref.read(privateModeStateProvider).isConfigured) return;
    final vaultOk = await HiddenVaultSession.instance.unlockFromSession();
    if (!mounted) return;
    if (!vaultOk) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сначала введите PIN в этой сессии')),
      );
      return;
    }
    final secretEnabled = await PrivacyPreferencesStore().secretRoomEnabled();
    if (!mounted) return;
    if (!secretEnabled) {
      setState(() {
        _error = 'Private Mode отключён в настройках';
        _input = '';
      });
      return;
    }
    _openSecretRoom();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(privateModeStateProvider);

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
          child: Column(
            children: [
              const SizedBox(height: AppSpacing.sectionGap * 2),
              const Icon(Icons.lock_outline, size: 40, color: AppColors.textPrimary),
              const SizedBox(height: AppSpacing.mediumGap),
              Text('Messenger', style: AppTypography.title),
              const Spacer(),
              if (!state.isConfigured) ...[
                Text(
                  'PIN ещё не настроен',
                  style: AppTypography.secondary,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.mediumGap),
                AppButton(
                  label: 'Создать PIN',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PinSetupScreen()),
                  ),
                ),
              ] else if (_lockedOut) ...[
                Text(
                  'Ввод PIN заблокирован',
                  style: AppTypography.secondary,
                  textAlign: TextAlign.center,
                ),
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
                PinKeypad(
                  onDigit: _onDigit,
                  onBackspace: _onBackspace,
                  onBiometric: state.biometricEnabled ? _onBiometricTap : null,
                ),
              ],
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
