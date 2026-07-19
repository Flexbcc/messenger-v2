import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../security/pin_security.dart';
import '../../services/privacy_preferences_store.dart';
import 'pin_keypad.dart';

/// Innocent-looking setup for the optional second PIN (decoy / duress PIN).
class DecoyPinSetupScreen extends ConsumerStatefulWidget {
  const DecoyPinSetupScreen({super.key, this.showSkip = false});

  /// After main PIN onboarding — allow skip to unlock next steps.
  final bool showSkip;

  @override
  ConsumerState<DecoyPinSetupScreen> createState() => _DecoyPinSetupScreenState();
}

class _DecoyPinSetupScreenState extends ConsumerState<DecoyPinSetupScreen> with SingleTickerProviderStateMixin {
  String _input = '';
  String? _pending;
  bool _confirmStep = false;
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

  void _onDigit(String d) {
    if (_input.length >= kPinLength) return;
    setState(() {
      _error = null;
      _input += d;
    });
    if (_input.length == kPinLength) {
      Future.delayed(const Duration(milliseconds: 120), _onComplete);
    }
  }

  void _onBackspace() {
    if (_input.isEmpty) return;
    setState(() => _input = _input.substring(0, _input.length - 1));
  }

  Future<void> _onComplete() async {
    if (!_confirmStep) {
      setState(() {
        _pending = _input;
        _input = '';
        _confirmStep = true;
      });
      return;
    }

    if (_input != _pending) {
      setState(() {
        _error = 'PIN не совпадает';
        _input = '';
        _confirmStep = false;
        _pending = null;
      });
      _shakeController.forward(from: 0);
      return;
    }

    await PinSecurity.saveFakePin(_input);
    await PrivacyPreferencesStore().setFakePinEnabled(true);
    await PrivacyPreferencesStore().setDecoyPinStepComplete(true);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _skip() async {
    await PrivacyPreferencesStore().setDecoyPinStepComplete(true);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    return Scaffold(
      appBar: AppBar(title: const Text('Дополнительный PIN')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          child: Column(
            children: [
              Text(
                _confirmStep ? 'Повторите дополнительный PIN' : 'Создайте дополнительный PIN',
                style: text.title,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Отдельный код: открывает безопасный интерфейс без секретов. '
                'Можно настроить оповещение доверенных (по умолчанию после 5 вводов). '
                'Должен отличаться от основного PIN.',
                style: text.caption,
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              ShakeOnError(
                controller: _shakeController,
                child: PinDotsIndicator(filledCount: _input.length),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(_error!, style: text.caption.copyWith(color: context.colors.danger)),
              ],
              const Spacer(),
              PinKeypad(onDigit: _onDigit, onBackspace: _onBackspace),
              if (widget.showSkip && !_confirmStep) ...[
                const SizedBox(height: AppSpacing.md),
                TextButton(
                  onPressed: _skip,
                  child: const Text('Пропустить — настроить позже'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
