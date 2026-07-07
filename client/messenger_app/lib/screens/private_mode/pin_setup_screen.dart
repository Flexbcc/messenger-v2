import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/colors.dart';
import '../../theme/spacing.dart';
import '../../theme/typography.dart';
import '../../widgets/app_button.dart';
import 'pin_keypad.dart';
import 'private_mode_state.dart';

enum _Step { enterPin, confirmPin, fakeChoice, enterFakePin, confirmFakePin, biometric }

/// "Создать PIN" — mock PIN setup flow for Private Mode.
///
/// Per spec/0402_PRIVATE_MODE.md this stores the PIN only in the in-memory
/// [PrivateModeState] (see private_mode_state.dart) for this module — there
/// is no real hashing, no secure storage, no persistence across app
/// restarts at this stage.
class PinSetupScreen extends ConsumerStatefulWidget {
  const PinSetupScreen({super.key});

  @override
  ConsumerState<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends ConsumerState<PinSetupScreen> with SingleTickerProviderStateMixin {
  _Step _step = _Step.enterPin;
  String _input = '';
  String? _pendingRealPin;
  String? _pendingFakePin;
  bool _biometricEnabled = false;
  bool _saving = false;
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
      Future.delayed(const Duration(milliseconds: 150), _onEntryComplete);
    }
  }

  void _onBackspace() {
    if (_input.isEmpty) return;
    setState(() => _input = _input.substring(0, _input.length - 1));
  }

  void _onEntryComplete() {
    if (!mounted) return;
    switch (_step) {
      case _Step.enterPin:
        setState(() {
          _pendingRealPin = _input;
          _input = '';
          _step = _Step.confirmPin;
        });
      case _Step.confirmPin:
        if (_input == _pendingRealPin) {
          setState(() {
            _input = '';
            _step = _Step.fakeChoice;
          });
        } else {
          _fail(resetTo: _Step.enterPin, clearPending: true);
        }
      case _Step.enterFakePin:
        setState(() {
          _pendingFakePin = _input;
          _input = '';
          _step = _Step.confirmFakePin;
        });
      case _Step.confirmFakePin:
        if (_input == _pendingFakePin) {
          setState(() {
            _input = '';
            _step = _Step.biometric;
          });
        } else {
          _fail(resetTo: _Step.enterFakePin, clearPending: false);
        }
      case _Step.fakeChoice:
      case _Step.biometric:
        break;
    }
  }

  void _fail({required _Step resetTo, required bool clearPending}) {
    setState(() {
      _error = 'PIN не совпадает, попробуйте снова';
      _input = '';
      _step = resetTo;
      if (clearPending) _pendingRealPin = null;
    });
    _shakeController.forward(from: 0);
  }

  Future<void> _finish() async {
    if (_saving || _pendingRealPin == null) return;
    setState(() => _saving = true);
    try {
      final state = ref.read(privateModeStateProvider);
      await state.configurePins(realPin: _pendingRealPin!, fakePin: _pendingFakePin);
      await state.setBiometricEnabled(_biometricEnabled);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось сохранить PIN: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String get _title => switch (_step) {
        _Step.enterPin => 'Создать PIN',
        _Step.confirmPin => 'Повторите PIN',
        _Step.fakeChoice => 'Fake PIN',
        _Step.enterFakePin => 'Создать Fake PIN',
        _Step.confirmFakePin => 'Повторите Fake PIN',
        _Step.biometric => 'Готово',
      };

  String get _explanation => switch (_step) {
        _Step.enterPin => 'PIN защищает доступ к приложению и приватным настройкам.',
        _Step.confirmPin => 'Введите PIN ещё раз для подтверждения.',
        _Step.fakeChoice =>
          'Можно дополнительно настроить отдельный PIN, который открывает обычный вид приложения без доступа к скрытым чатам. Это необязательно.',
        _Step.enterFakePin => 'Придумайте PIN, отличный от основного.',
        _Step.confirmFakePin => 'Введите Fake PIN ещё раз для подтверждения.',
        _Step.biometric => 'На десктопе Face ID — заглушка. Переключатель сохраняет настройку для будущей интеграции.',
      };

  bool get _isPinStep => switch (_step) {
        _Step.enterPin || _Step.confirmPin || _Step.enterFakePin || _Step.confirmFakePin => true,
        _ => false,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundLight,
        elevation: 0,
        foregroundColor: AppColors.textPrimary,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Закрыть',
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
          child: Column(
            children: [
              const SizedBox(height: AppSpacing.sectionGap),
              Text(_title, style: AppTypography.largeTitle, textAlign: TextAlign.center),
              const SizedBox(height: AppSpacing.smallGap),
              Text(
                _explanation,
                style: AppTypography.secondary,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sectionGap),
              Expanded(child: _buildStepBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepBody() {
    if (_isPinStep) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
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
      );
    }

    if (_step == _Step.fakeChoice) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppButton(
            label: 'Настроить Fake PIN',
            variant: AppButtonVariant.secondary,
            onPressed: () => setState(() {
              _input = '';
              _step = _Step.enterFakePin;
            }),
          ),
          const SizedBox(height: AppSpacing.mediumGap),
          AppButton(
            label: 'Пропустить',
            variant: AppButtonVariant.primary,
            onPressed: () => setState(() => _step = _Step.biometric),
          ),
        ],
      );
    }

    // _Step.biometric
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.cardPadding),
          decoration: BoxDecoration(
            color: AppColors.surfaceLight,
            borderRadius: BorderRadius.circular(AppRadii.medium),
          ),
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Включить Face ID / Touch ID', style: AppTypography.body),
            subtitle: Text('Пока mock — на Mac не используется', style: AppTypography.caption),
            value: _biometricEnabled,
            activeThumbColor: AppColors.accentBlue,
            onChanged: _saving ? null : (v) => setState(() => _biometricEnabled = v),
          ),
        ),
        const SizedBox(height: AppSpacing.sectionGap),
        AppButton(label: 'Готово', loading: _saving, onPressed: _saving ? null : _finish),
        const SizedBox(height: AppSpacing.mediumGap),
        AppButton(
          label: 'Пропустить',
          variant: AppButtonVariant.secondary,
          onPressed: _saving
              ? null
              : () {
                  setState(() => _biometricEnabled = false);
                  _finish();
                },
        ),
      ],
    );
  }
}
