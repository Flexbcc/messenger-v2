import 'package:flutter/material.dart';

import '../screens/private_mode/pin_keypad.dart';
import '../services/app_lock_service.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

/// Full-screen PIN gate shown when App Lock is enabled and app resumes.
class AppLockOverlay extends StatefulWidget {
  const AppLockOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<AppLockOverlay> createState() => _AppLockOverlayState();
}

class _AppLockOverlayState extends State<AppLockOverlay> with SingleTickerProviderStateMixin {
  final _lock = AppLockService.instance;
  String _input = '';
  String? _error;
  late final AnimationController _shakeController;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _lock.addListener(_onLockChanged);
  }

  @override
  void dispose() {
    _lock.removeListener(_onLockChanged);
    _shakeController.dispose();
    super.dispose();
  }

  void _onLockChanged() {
    if (mounted) setState(() {});
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
    final ok = await _lock.verifyPin(_input);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _error = 'Неверный PIN';
        _input = '';
      });
      _shakeController.forward(from: 0);
      return;
    }
    _lock.unlock();
    setState(() {
      _input = '';
      _error = null;
    });
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
