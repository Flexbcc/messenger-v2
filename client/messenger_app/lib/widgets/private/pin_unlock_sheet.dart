import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../models/duress_policy.dart';
import '../../screens/private_mode/fake_mode_screen.dart';
import '../../screens/private_mode/pin_keypad.dart';
import '../../screens/private_mode/private_mode_state.dart';
import '../../security/pin_security.dart';
import '../../services/duress_policy_engine.dart';
import '../../services/duress_policy_session.dart';
import '../../services/hidden_vault_session.dart';
import '../../services/privacy_preferences_store.dart';
import '../../state/app_controller.dart';

/// Short PIN prompt for editing vault-protected settings from the main app.
Future<bool> showPinUnlockSheet(BuildContext context) async {
  final configured = await PinSecurity.isRealPinConfigured();
  if (!configured) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сначала создайте PIN в настройках')),
      );
    }
    return false;
  }
  if (HiddenVaultSession.instance.isUnlocked && DuressPolicySession.instance.isUnlocked) {
    return true;
  }
  final pin = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => const _PinUnlockBody(),
  );
  if (pin == null || pin.isEmpty) return false;
  if (pin == '__decoy__') return false;
  final secretEnabled = await PrivacyPreferencesStore().secretRoomEnabled();
  if (!secretEnabled) return false;
  final vaultOk = await HiddenVaultSession.instance.unlock(pin);
  if (!vaultOk) return false;
  await DuressPolicySession.instance.unlock(pin);
  return true;
}

class _PinUnlockBody extends ConsumerStatefulWidget {
  const _PinUnlockBody();

  @override
  ConsumerState<_PinUnlockBody> createState() => _PinUnlockBodyState();
}

class _PinUnlockBodyState extends ConsumerState<_PinUnlockBody> with SingleTickerProviderStateMixin {
  String _input = '';
  String? _error;
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

  Future<void> _submit() async {
    final pm = ref.read(privateModeStateProvider);
    final controller = ref.read(appControllerProvider);
    final result = await pm.evaluate(_input);
    if (!mounted) return;

    if (result == UnlockResult.fakePin) {
      final hr = await DuressPolicyEngine.instance.handle(
        DuressTrigger.decoyPinStreak,
        controller: controller,
      );
      if (!mounted) return;
      if (hr.openDecoy) {
        final nav = Navigator.of(context);
        nav.pop('__decoy__');
        nav.push(MaterialPageRoute(builder: (_) => const FakeModeScreen()));
        return;
      }
      setState(() {
        _error = 'Неверный PIN';
        _input = '';
      });
      _shakeController.forward(from: 0);
      return;
    }

    if (result != UnlockResult.realPin) {
      final hr = await DuressPolicyEngine.instance.handle(
        DuressTrigger.pinUnlockFail,
        controller: controller,
      );
      setState(() {
        _error = hr.lockoutUntil != null
            ? 'Слишком много попыток. Подождите…'
            : 'Неверный PIN';
        _input = '';
      });
      _shakeController.forward(from: 0);
      return;
    }

    await DuressPolicyEngine.instance.handle(
      DuressTrigger.pinUnlockOkReal,
      controller: controller,
      incrementCounter: false,
    );
    if (!mounted) return;
    Navigator.pop(context, _input);
  }

  void _onDigit(String d) {
    if (_input.length >= kPinLength) return;
    setState(() {
      _error = null;
      _input += d;
    });
    if (_input.length == kPinLength) {
      Future.delayed(const Duration(milliseconds: 120), _submit);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Введите PIN', style: text.title),
            const SizedBox(height: AppSpacing.sm),
            Text('Нужен для доступа к защищённым настройкам', style: text.caption, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.lg),
            ShakeOnError(
              controller: _shakeController,
              child: PinDotsIndicator(filledCount: _input.length),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(_error!, style: text.caption.copyWith(color: context.colors.danger)),
            ],
            const SizedBox(height: AppSpacing.lg),
            PinKeypad(
              onDigit: _onDigit,
              onBackspace: () {
                if (_input.isEmpty) return;
                setState(() => _input = _input.substring(0, _input.length - 1));
              },
            ),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    );
  }
}
