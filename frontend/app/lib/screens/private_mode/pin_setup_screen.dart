import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/colors.dart';
import '../../theme/spacing.dart';
import '../../theme/typography.dart';
import '../../widgets/app_button.dart';
import '../../services/duress_policy_session.dart';
import '../../services/privacy_preferences_store.dart';
import '../../services/settings_runtime.dart';
import '../../services/local_settings_store.dart';
import '../../services/settings_catalog_bridge.dart';
import 'decoy_pin_setup_screen.dart';
import 'pin_keypad.dart';
import 'private_mode_state.dart';

enum _Step { enterPin, confirmPin }

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

class _PinSetupScreenState extends ConsumerState<PinSetupScreen>
    with SingleTickerProviderStateMixin {
  _Step _step = _Step.enterPin;
  String _input = '';
  String? _pendingRealPin;
  bool _saving = false;
  String? _error;
  int _pinLength = kPinLength;
  bool _alphanumeric = false;

  late final AnimationController _shakeController;
  final _alphaCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    Future.microtask(_loadPinPolicy);
  }

  Future<void> _loadPinPolicy() async {
    final len = await SettingsRuntime.instance.pinLength();
    final alpha = await SettingsRuntime.instance.alphanumericPassword();
    if (!mounted) return;
    setState(() {
      _pinLength = len.clamp(4, 12);
      _alphanumeric = alpha;
    });
  }

  @override
  void dispose() {
    _shakeController.dispose();
    _alphaCtrl.dispose();
    super.dispose();
  }

  void _onDigit(String d) {
    if (_input.length >= _pinLength) return;
    setState(() {
      _error = null;
      _input += d;
    });
    if (_input.length == _pinLength) {
      Future.delayed(const Duration(milliseconds: 150), _onEntryComplete);
    }
  }

  void _onBackspace() {
    if (_input.isEmpty) return;
    setState(() => _input = _input.substring(0, _input.length - 1));
  }

  Future<void> _onEntryComplete() async {
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
          setState(() => _input = '');
          await _finish();
        } else {
          _fail(resetTo: _Step.enterPin, clearPending: true);
        }
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
      await state.configurePins(realPin: _pendingRealPin!);
      await PrivacyPreferencesStore().setAppLockEnabled(true);
      await LocalSettingsStore().setBool(
        SettingsCatalogBridge.catalogKey('security.pin_enabled'),
        true,
      );
      await DuressPolicySession.instance.unlock(_pendingRealPin!);
      if (!mounted) return;
      final decoyDone = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => const DecoyPinSetupScreen(showSkip: true),
        ),
      );
      if (!mounted) return;
      if (decoyDone != true) {
        await PrivacyPreferencesStore().setDecoyPinStepComplete(true);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Не удалось сохранить PIN: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String get _title => switch (_step) {
    _Step.enterPin => 'Создать PIN',
    _Step.confirmPin => 'Повторите PIN',
  };

  String get _explanation => switch (_step) {
    _Step.enterPin =>
      _alphanumeric
          ? 'Пароль ($_pinLength+ символов, буквы и цифры) защищает доступ к приложению.'
          : 'PIN из $_pinLength цифр защищает доступ к приложению и приватным настройкам.',
    _Step.confirmPin =>
      'Введите ${_alphanumeric ? 'пароль' : 'PIN'} ещё раз для подтверждения.',
  };

  bool get _isPinStep => true;

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
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenPadding,
          ),
          child: Column(
            children: [
              const SizedBox(height: AppSpacing.sectionGap),
              Text(
                _title,
                style: AppTypography.largeTitle,
                textAlign: TextAlign.center,
              ),
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
      if (_alphanumeric) {
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _alphaCtrl,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Минимум $_pinLength символов',
                errorText: _error,
              ),
              onSubmitted: (_) {
                final v = _alphaCtrl.text;
                if (v.length < _pinLength) {
                  setState(() => _error = 'Слишком короткий пароль');
                  return;
                }
                setState(() {
                  _input = v;
                  _error = null;
                });
                _onEntryComplete();
                _alphaCtrl.clear();
              },
            ),
            const SizedBox(height: AppSpacing.sectionGap),
            AppButton(
              label: 'Далее',
              onPressed: () {
                final v = _alphaCtrl.text;
                if (v.length < _pinLength) {
                  setState(() => _error = 'Слишком короткий пароль');
                  return;
                }
                setState(() {
                  _input = v;
                  _error = null;
                });
                _onEntryComplete();
                _alphaCtrl.clear();
              },
            ),
          ],
        );
      }
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
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
                      color: AppColors.dangerRed,
                    ),
                  )
                : null,
          ),
          const SizedBox(height: AppSpacing.sectionGap),
          PinKeypad(onDigit: _onDigit, onBackspace: _onBackspace),
        ],
      );
    }

    return const SizedBox.shrink();
  }
}
