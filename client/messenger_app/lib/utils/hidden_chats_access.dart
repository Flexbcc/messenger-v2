import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../models/duress_policy.dart';
import '../screens/private_mode/fake_mode_screen.dart';
import '../screens/private_mode/hidden_chats_screen.dart';
import '../screens/private_mode/pin_keypad.dart';
import '../screens/private_mode/private_mode_state.dart';
import '../security/pin_security.dart';
import '../services/app_privacy_session.dart';
import '../services/duress_policy_engine.dart';
import '../services/duress_policy_session.dart';
import '../services/hidden_vault_session.dart';
import '../state/app_controller.dart';

/// PIN gate before opening hidden chats (outside full Private Mode flow).
class HiddenChatsAccess {
  HiddenChatsAccess._();

  static Future<bool> openWithPin(BuildContext context) async {
    if (!await PinSecurity.isRealPinConfigured()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Сначала настройте PIN в настройках конфиденциальности')),
        );
      }
      return false;
    }

    if (!context.mounted) return false;

    final pin = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => const _HiddenChatsPinSheet(),
    );
    if (pin == null || pin.isEmpty || pin == '__decoy__') return false;

    if (!context.mounted) return false;
    await HiddenVaultSession.instance.unlock(pin);
    await DuressPolicySession.instance.unlock(pin);
    if (!context.mounted) return false;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HiddenChatsScreen()));
    return true;
  }
}

class _HiddenChatsPinSheet extends ConsumerStatefulWidget {
  const _HiddenChatsPinSheet();

  @override
  ConsumerState<_HiddenChatsPinSheet> createState() => _HiddenChatsPinSheetState();
}

class _HiddenChatsPinSheetState extends ConsumerState<_HiddenChatsPinSheet>
    with SingleTickerProviderStateMixin {
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
      AppPrivacySession.instance.enterDecoyMode();
      controller.deactivateSecretSessionForAll();
      await DuressPolicyEngine.instance.handle(
        DuressTrigger.decoyPinStreak,
        controller: controller,
      );
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pop('__decoy__');
      nav.push(MaterialPageRoute(builder: (_) => const FakeModeScreen()));
      return;
    }

    if (result != UnlockResult.realPin) {
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

    await DuressPolicyEngine.instance.handle(
      DuressTrigger.pinUnlockOkReal,
      controller: controller,
      incrementCounter: false,
    );
    if (!mounted) return;
    Navigator.pop(context, _input);
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
            Text('Скрытые чаты', style: text.title),
            const SizedBox(height: AppSpacing.sm),
            Text('Введите основной PIN', style: text.caption),
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
              onDigit: (d) {
                if (_input.length >= kPinLength) return;
                setState(() {
                  _error = null;
                  _input += d;
                });
                if (_input.length == kPinLength) {
                  Future.delayed(const Duration(milliseconds: 120), _submit);
                }
              },
              onBackspace: () {
                if (_input.isEmpty) return;
                setState(() => _input = _input.substring(0, _input.length - 1));
              },
            ),
          ],
        ),
      ),
    );
  }
}
