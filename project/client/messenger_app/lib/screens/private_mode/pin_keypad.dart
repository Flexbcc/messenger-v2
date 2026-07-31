import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/colors.dart';
import '../../theme/spacing.dart';
import '../../theme/typography.dart';

/// Shared numeric keypad + dot indicator for the Private Mode module
/// (pin_setup_screen.dart, unlock_screen.dart). Kept local to this module
/// rather than in lib/widgets/ since it is specific to the mock PIN flows
/// here — no other part of the app uses a PIN pad.

const int kPinLength = 6;

/// Row of dots showing how many digits have been entered so far.
class PinDotsIndicator extends StatelessWidget {
  const PinDotsIndicator({super.key, required this.filledCount, this.length = kPinLength});

  final int filledCount;
  final int length;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(length, (i) {
        final filled = i < filledCount;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: AppSpacing.smallGap / 2),
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? AppColors.textPrimary : AppColors.backgroundLight,
            border: Border.all(color: AppColors.borderLight, width: filled ? 0 : 1.5),
          ),
        );
      }),
    );
  }
}

/// Wraps [child] with a horizontal shake — used to signal a wrong PIN
/// without any other visual drama (per spec: stay calm/neutral).
class ShakeOnError extends StatefulWidget {
  const ShakeOnError({super.key, required this.controller, required this.child});

  final AnimationController controller;
  final Widget child;

  @override
  State<ShakeOnError> createState() => ShakeOnErrorState();
}

class ShakeOnErrorState extends State<ShakeOnError> {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, child) {
        final t = widget.controller.value;
        final offset = math.sin(t * math.pi * 6) * 10 * (1 - t);
        return Transform.translate(offset: Offset(offset, 0), child: child);
      },
      child: widget.child,
    );
  }
}

/// Simple 0-9 + backspace grid. No package — plain GridView-like layout via
/// Column/Row so we keep full control over sizing per design.md spacing.
class PinKeypad extends StatelessWidget {
  const PinKeypad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    this.onBiometric,
    this.biometricIcon = Icons.fingerprint,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final VoidCallback? onBiometric;
  final IconData biometricIcon;

  static const _rows = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in _rows)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.mediumGap),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [for (final d in row) _KeypadButton(label: d, onTap: () => onDigit(d))],
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (onBiometric != null)
              _KeypadButton(icon: biometricIcon, onTap: onBiometric)
            else
              const SizedBox(width: 72),
            _KeypadButton(label: '0', onTap: () => onDigit('0')),
            _KeypadButton(icon: Icons.backspace_outlined, onTap: onBackspace),
          ],
        ),
      ],
    );
  }
}

class _KeypadButton extends StatelessWidget {
  const _KeypadButton({this.label, this.icon, this.onTap});

  final String? label;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 72,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Center(
            child: label != null
                ? Text(label!, style: AppTypography.largeTitle)
                : Icon(icon, color: AppColors.textPrimary, size: 26),
          ),
        ),
      ),
    );
  }
}
