import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/colors.dart';
import '../../theme/spacing.dart';
import '../../theme/typography.dart';
import '../../widgets/app_button.dart';
import '../../services/security_log_service.dart';
import '../../services/hidden_vault_session.dart';
import '../../services/privacy_preferences_store.dart';
import 'fake_mode_screen.dart';
import 'pin_keypad.dart';
import 'pin_setup_screen.dart';
import 'private_mode_state.dart';
import 'private_home_screen.dart';

/// PIN entry screen for the Private Mode module.
///
/// Per spec/0402_PRIVATE_MODE.md: entering the real PIN opens Secret Room,
/// entering the configured fake/decoy PIN opens an indistinguishable
/// "boring" mode, and anything else is rejected in place with no hint about
/// which part was wrong. All comparisons here are a mock in-memory string
/// check (see private_mode_state.dart) — not a real credential check.
class UnlockScreen extends ConsumerStatefulWidget {
  const UnlockScreen({super.key});

  @override
  ConsumerState<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<UnlockScreen> with SingleTickerProviderStateMixin {
  String _input = '';
  String? _error;
  int _wrongAttempts = 0;
  late final AnimationController _shakeController;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  void _onDigit(String d) {
    if (_input.length >= kPinLength) return;
    setState(() {
      _error = null;
      _input += d;
    });
    if (_input.length == kPinLength) {
      Future.delayed(const Duration(milliseconds: 120), _evaluate);
    }
  }

  void _onBackspace() {
    if (_input.isEmpty) return;
    setState(() => _input = _input.substring(0, _input.length - 1));
  }

  Future<void> _evaluate() async {
    final pm = ref.read(privateModeStateProvider);
    final prefs = PrivacyPreferencesStore();
    final result = await pm.evaluate(_input);
    if (!mounted) return;

    if (result == UnlockResult.invalid) {
      // Wipe after repeated failures if enabled.
      if (await prefs.wipeOnWrongAttempts()) {
        _wrongAttempts++;
        if (_wrongAttempts >= 5) {
          await pm.reset();
          await HiddenVaultSession.instance.wipe();
          _wrongAttempts = 0;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Данные Private Mode удалены')),
            );
          }
        }
      }
      setState(() {
        _error = 'Неверный PIN';
        _input = '';
      });
      _shakeController.forward(from: 0);
      return;
    }

    if (result == UnlockResult.fakePin) {
      final fakeEnabled = await prefs.fakePinEnabled();
      if (!fakeEnabled) {
        setState(() {
          _error = 'Неверный PIN';
          _input = '';
        });
        _shakeController.forward(from: 0);
        return;
      }
      _openFakeMode();
      return;
    }

    final secretEnabled = await prefs.secretRoomEnabled();
    if (!secretEnabled) {
      setState(() {
        _error = 'Private Mode отключён в настройках';
        _input = '';
      });
      return;
    }
    final vaultOk = await HiddenVaultSession.instance.unlock(_input);
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
    SecurityLogService.instance.append(
      SecurityEvent(title: 'Secret Room открыт', subtitle: 'Успешный PIN', at: DateTime.now(), icon: 'room'),
    );
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const PrivateHomeScreen()));
  }

  void _openFakeMode() {
    HiddenVaultSession.instance.lock();
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
