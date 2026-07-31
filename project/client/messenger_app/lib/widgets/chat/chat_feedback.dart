import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';

/// Brief non-blocking feedback — no SnackBar, does not steal focus from input.
class ChatFeedback {
  ChatFeedback._();

  static OverlayEntry? _active;

  static void show(
    BuildContext context, {
    required IconData icon,
    Color? iconColor,
    String? label,
    Duration hold = const Duration(milliseconds: 900),
  }) {
    _active?.remove();
    _active = null;

    HapticFeedback.lightImpact();
    final overlay = Overlay.of(context, rootOverlay: true);
    final colors = context.colors;
    final text = context.textStyles;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _FeedbackBubble(
        icon: icon,
        iconColor: iconColor ?? colors.primary,
        label: label,
        textStyle: text.caption,
        onDone: () {
          entry.remove();
          if (_active == entry) _active = null;
        },
        hold: hold,
      ),
    );
    _active = entry;
    overlay.insert(entry);
  }

  static void copied(BuildContext context) {
    show(context, icon: Icons.check_rounded, iconColor: context.colors.success);
  }

  static void pinned(BuildContext context, {required bool pinned}) {
    show(
      context,
      icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
      label: pinned ? 'Закреплено' : 'Откреплено',
    );
  }

  static void reminderSet(BuildContext context, DateTime when) {
    final hh = when.hour.toString().padLeft(2, '0');
    final mm = when.minute.toString().padLeft(2, '0');
    show(
      context,
      icon: Icons.alarm_rounded,
      label: 'Напоминание $hh:$mm',
      hold: const Duration(milliseconds: 1400),
    );
  }

  static void addedToFavorites(BuildContext context) {
    show(context, icon: Icons.star_rounded, iconColor: context.colors.warning);
  }

  static void hidden(BuildContext context) {
    show(context, icon: Icons.visibility_off_outlined);
  }

  static void forwarded(BuildContext context) {
    show(context, icon: Icons.forward_rounded);
  }
}

class _FeedbackBubble extends StatefulWidget {
  const _FeedbackBubble({
    required this.icon,
    required this.iconColor,
    required this.onDone,
    required this.hold,
    required this.textStyle,
    this.label,
  });

  final IconData icon;
  final Color iconColor;
  final String? label;
  final TextStyle textStyle;
  final VoidCallback onDone;
  final Duration hold;

  @override
  State<_FeedbackBubble> createState() => _FeedbackBubbleState();
}

class _FeedbackBubbleState extends State<_FeedbackBubble> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
    _scale = Tween<double>(begin: 0.82, end: 1).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));
    _opacity = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _controller.forward();
    Future<void>.delayed(widget.hold, () async {
      if (!mounted) return;
      await _controller.reverse();
      widget.onDone();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xl * 2),
            child: FadeTransition(
              opacity: _opacity,
              child: ScaleTransition(
                scale: _scale,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: context.colors.surfaceElevated.withValues(alpha: 0.94),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: context.colors.divider),
                      boxShadow: [
                        BoxShadow(
                          color: context.colors.shadow.withValues(alpha: 0.35),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(widget.icon, size: 18, color: widget.iconColor),
                        if (widget.label != null) ...[
                          const SizedBox(width: 8),
                          Text(widget.label!, style: widget.textStyle),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
