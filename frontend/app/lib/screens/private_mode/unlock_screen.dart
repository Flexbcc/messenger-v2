import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../theme/spacing.dart';
import '../../theme/typography.dart';
import '../../widgets/app_button.dart';
import '../../services/security_log_service.dart';
import '../../services/hidden_vault_session.dart';
import '../../services/app_privacy_session.dart';
import '../../services/duress_policy_engine.dart';
import '../../services/duress_policy_session.dart';
import '../../services/duress_rate_limiter.dart';
import '../../services/privacy_preferences_store.dart';
import '../../services/settings_catalog_bridge.dart';
import '../../services/settings_runtime.dart';
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

class _UnlockScreenState extends ConsumerState<UnlockScreen>
    with SingleTickerProviderStateMixin {
  String _input = '';
  String? _error;
  int _wrongAttempts = 0;
  bool _lockedOut = false;
  Duration? _lockoutRemaining;
  int _pinLength = kPinLength;
  bool _alphanumeric = false;
  final _passwordController = TextEditingController();
  Timer? _lockoutTimer;
  late final AnimationController _shakeController;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _refreshLockout();
    _loadPinPolicy();
  }

  Future<void> _loadPinPolicy() async {
    final length = await SettingsRuntime.instance.pinLength();
    final alphanumeric = await SettingsRuntime.instance.alphanumericPassword();
    if (!mounted) return;
    setState(() {
      _pinLength = length.clamp(4, 12);
      _alphanumeric = alphanumeric;
    });
  }

  @override
  void dispose() {
    _lockoutTimer?.cancel();
    _passwordController.dispose();
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
      _lockoutTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _refreshLockout(),
      );
    }
  }

  String _formatLockout(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _onDigit(String d) {
    if (_lockedOut || _input.length >= _pinLength) return;
    setState(() {
      _error = null;
      _input += d;
    });
    if (_input.length == _pinLength) {
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
    if (_alphanumeric) _passwordController.clear();
    final result = await pm.evaluate(pin);
    if (!mounted) return;

    if (result == UnlockResult.invalid) {
      if (await prefs.wipeOnWrongAttempts()) {
        _wrongAttempts++;
        final wipeRaw = await CatalogSettingsReader().getString(
          'security.wipe_after',
          '15',
        );
        final wipeAfter = int.tryParse(wipeRaw) ?? 15;
        // pin_attempt_policy: delays via DuressRateLimiter.lockoutForAttempt (consumed by policy engine).
        DuressRateLimiter.lockoutForAttempt(_wrongAttempts);
        if (_wrongAttempts >= wipeAfter) {
          await pm.reset();
          await controller.wipeLocalContentAfterPinFailures();
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
      if (!await prefs.fakePinEnabled() || !await PinSecurity.hasFakePin()) {
        await DuressPolicyEngine.instance.handle(
          DuressTrigger.pinUnlockFail,
          controller: controller,
        );
        setState(() {
          _error = 'Неверный PIN';
          _input = '';
        });
        _shakeController.forward(from: 0);
        return;
      }
      AppPrivacySession.instance.enterDecoyMode();
      controller.deactivateSecretSessionForAll();
      await controller.reloadFakeProfileChats();
      await DuressPolicyEngine.instance.handle(
        DuressTrigger.decoyPinStreak,
        controller: controller,
      );
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
      SecurityEvent(
        title: 'Secret Room открыт',
        subtitle: 'Успешный PIN',
        at: DateTime.now(),
        icon: 'room',
      ),
    );
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const PrivateHomeScreen()),
    );
  }

  void _openFakeMode() {
    HiddenVaultSession.instance.lock();
    DuressPolicySession.instance.lock();
    AppPrivacySession.instance.enterDecoyMode();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const FakeModeScreen()),
    );
  }

  void _closeWithoutUnlock() {
    // Soft exit — leave Private Mode without unlocking or triggering panic/duress.
    Navigator.of(context, rootNavigator: true).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(privateModeStateProvider);
    final colors = context.colors;

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        elevation: 0,
        foregroundColor: colors.textPrimary,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Закрыть',
            onPressed: _closeWithoutUnlock,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenPadding,
          ),
          child: Column(
            children: [
              const SizedBox(height: AppSpacing.sectionGap),
              Icon(Icons.lock_outline, size: 40, color: colors.textPrimary),
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
                  _lockoutRemaining != null
                      ? _formatLockout(_lockoutRemaining!)
                      : '…',
                  style: AppTypography.largeTitle,
                ),
              ] else ...[
                if (_alphanumeric)
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: 'Пароль',
                      errorText: _error,
                    ),
                    onSubmitted: (value) {
                      if (value.length < _pinLength) {
                        setState(() => _error = 'Минимум $_pinLength символов');
                        return;
                      }
                      _input = value;
                      _evaluate();
                    },
                  )
                else
                  ShakeOnError(
                    controller: _shakeController,
                    child: PinDotsIndicator(
                      filledCount: _input.length,
                      length: _pinLength,
                    ),
                  ),
                const SizedBox(height: AppSpacing.smallGap),
                SizedBox(
                  height: 20,
                  child: _error != null
                      ? Text(
                          _error!,
                          style: AppTypography.caption.copyWith(
                            color: colors.danger,
                          ),
                        )
                      : null,
                ),
                const SizedBox(height: AppSpacing.sectionGap),
                if (!_alphanumeric)
                  PinKeypad(onDigit: _onDigit, onBackspace: _onBackspace)
                else
                  AppButton(
                    label: 'Открыть',
                    onPressed: () {
                      final value = _passwordController.text;
                      if (value.length < _pinLength) {
                        setState(() => _error = 'Минимум $_pinLength символов');
                        return;
                      }
                      _input = value;
                      _evaluate();
                    },
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
