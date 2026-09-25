import 'package:flutter/material.dart';

import '../calls/call_signal.dart';
import '../core/extensions/context_extensions.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';
import '../utils/call_format.dart';

/// Presentational full-screen call UI (no WebRTC). Used by [CallScreen] and
/// the screenshot harness.
class CallStage extends StatelessWidget {
  const CallStage({
    super.key,
    required this.peerName,
    required this.kind,
    required this.outgoing,
    required this.answered,
    this.elapsed = Duration.zero,
    this.waitingForNetwork = false,
    this.muted = false,
    this.speakerOn = false,
    this.onHold = false,
    this.showVideoPlaceholder = false,
    this.background,
    this.onToggleMute,
    this.onToggleSpeaker,
    this.onToggleHold,
    this.onReject,
    this.onAnswer,
    this.onCancel,
    this.onEnd,
    this.onMinimize,
  });

  final String peerName;
  final CallKind kind;
  final bool outgoing;
  final bool answered;
  final Duration elapsed;
  final bool waitingForNetwork;
  final bool muted;
  final bool speakerOn;
  final bool onHold;
  final bool showVideoPlaceholder;
  final Widget? background;
  final VoidCallback? onToggleMute;
  final VoidCallback? onToggleSpeaker;
  final VoidCallback? onToggleHold;
  final VoidCallback? onReject;
  final VoidCallback? onAnswer;
  final VoidCallback? onCancel;
  final VoidCallback? onEnd;
  final VoidCallback? onMinimize;

  String get statusText {
    if (!answered) return outgoing ? 'Звоним…' : 'Входящий звонок';
    if (waitingForNetwork) return 'Ожидание сети…';
    if (onHold) return 'На удержании';
    if (speakerOn) return 'Громкая связь';
    return kind == CallKind.video ? 'Видеозвонок' : 'Разговор';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Фон: видео / кастомный / красивый градиент с аватаром
          if (background != null)
            background!
          else if (showVideoPlaceholder)
            const _VideoPlaceholder()
          else
            _CallBackground(peerName: peerName),

          // Тёмный оверлей для читаемости текста
          if (background == null && !showVideoPlaceholder)
            const SizedBox.shrink()
          else
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.5),
                    Colors.black.withValues(alpha: 0.3),
                    Colors.black.withValues(alpha: 0.6),
                  ],
                  stops: const [0, 0.4, 1],
                ),
              ),
            ),

          SafeArea(
            child: Stack(
              children: [
                // Имя + статус вверху
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sectionGap),
                    child: Column(
                      children: [
                        Text(
                          peerName,
                          style: AppTypography.title.copyWith(
                            color: Colors.white,
                            fontSize: 22,
                            shadows: [
                              Shadow(blurRadius: 8, color: Colors.black45),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        _StatusText(
                          text: statusText,
                          isWarning: waitingForNetwork,
                          answered: answered,
                        ),
                        if (answered) ...[
                          const SizedBox(height: 10),
                          Text(
                            formatCallDuration(elapsed),
                            style: AppTypography.largeTitle.copyWith(
                              color: Colors.white,
                              fontSize: 26,
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                // Кнопка свернуть
                if (onMinimize != null)
                  Positioned(
                    top: 4,
                    right: AppSpacing.screenPadding,
                    child: IconButton(
                      icon: const Icon(
                        Icons.keyboard_arrow_down,
                        color: Colors.white,
                        size: 32,
                      ),
                      tooltip: 'Свернуть',
                      onPressed: onMinimize,
                    ),
                  ),

                // Кнопки управления внизу
                Positioned(
                  bottom: AppSpacing.sectionGap * 1.5,
                  left: 0,
                  right: 0,
                  child: _CallControls(
                    answered: answered,
                    outgoing: outgoing,
                    muted: muted,
                    speakerOn: speakerOn,
                    onHold: onHold,
                    onToggleMute: onToggleMute,
                    onToggleSpeaker: onToggleSpeaker,
                    onToggleHold: onToggleHold,
                    onReject: onReject,
                    onAnswer: onAnswer,
                    onCancel: onCancel,
                    onEnd: onEnd,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Brief full-screen “call ended” frame for product + screenshots.
class CallEndedOverlay extends StatelessWidget {
  const CallEndedOverlay({super.key, required this.peerName, this.onDismiss});

  final String peerName;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: colors.background.withValues(alpha: 0.96),
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.call_end, color: colors.danger, size: 48),
              const SizedBox(height: 16),
              Text(
                'Звонок завершён',
                style: AppTypography.title.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                peerName,
                style: AppTypography.secondary.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              if (onDismiss != null) ...[
                const SizedBox(height: 24),
                TextButton(
                  onPressed: onDismiss,
                  child: Text(
                    'Закрыть',
                    style: TextStyle(color: colors.primary),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Красивый фон звонка — градиент primary→secondary + крупный аватар с блюром
class _CallBackground extends StatelessWidget {
  const _CallBackground({required this.peerName});
  final String peerName;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final colorA = colors.primary;
    final colorB = Color.lerp(colors.primary, colors.background, 0.48)!;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Основной градиент
        Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, -0.3),
              radius: 1.4,
              colors: [
                colorA.withValues(alpha: 0.88),
                colorB,
                colors.background,
              ],
              stops: const [0, 0.48, 1],
            ),
          ),
        ),
        // Декоративные кольца — пульсирующие
        _PulseRings(color: colorA),
        // Крупный аватар по центру (чуть выше середины)
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 60),
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [colorA.withValues(alpha: 0.9), colorB],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: colorA.withValues(alpha: 0.4),
                      blurRadius: 40,
                      spreadRadius: 8,
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    peerName.isNotEmpty
                        ? peerName
                              .trim()
                              .split(' ')
                              .map((w) => w.isNotEmpty ? w[0] : '')
                              .take(2)
                              .join()
                              .toUpperCase()
                        : '?',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 42,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Анимированные кольца вокруг аватара
class _PulseRings extends StatefulWidget {
  const _PulseRings({required this.color});
  final Color color;

  @override
  State<_PulseRings> createState() => _PulseRingsState();
}

class _PulseRingsState extends State<_PulseRings>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) {
        final t = _anim.value;
        return CustomPaint(
          painter: _RingPainter(color: widget.color, progress: t),
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.color, required this.progress});
  final Color color;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 + 30);
    for (var i = 0; i < 3; i++) {
      final t = ((progress + i / 3) % 1.0);
      final radius = 70.0 + t * 130;
      final opacity = (1 - t) * 0.18;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = color.withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress;
}

/// Анимированный статус — точки для "Звоним…"
class _StatusText extends StatefulWidget {
  const _StatusText({
    required this.text,
    required this.isWarning,
    required this.answered,
  });
  final String text;
  final bool isWarning;
  final bool answered;

  @override
  State<_StatusText> createState() => _StatusTextState();
}

class _StatusTextState extends State<_StatusText>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  int _dots = 0;

  @override
  void initState() {
    super.initState();
    _ctrl =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 600),
        )..addStatusListener((s) {
          if (s == AnimationStatus.completed) {
            if (mounted) setState(() => _dots = (_dots + 1) % 4);
            _ctrl.forward(from: 0);
          }
        });
    if (!widget.answered) _ctrl.forward();
  }

  @override
  void didUpdateWidget(_StatusText old) {
    super.didUpdateWidget(old);
    if (widget.answered && !old.answered) _ctrl.stop();
    if (!widget.answered && old.answered) _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showDots =
        !widget.answered &&
        (widget.text.contains('Звон') || widget.text.contains('Ожид'));
    final label = showDots
        ? '${widget.text.replaceAll('…', '')}${'.' * _dots}   '
        : widget.text;
    return Text(
      label,
      style: TextStyle(
        color: widget.isWarning
            ? context.colors.warning
            : Colors.white.withValues(alpha: 0.75),
        fontSize: 15,
        fontWeight: FontWeight.w400,
      ),
    );
  }
}

class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.45),
      child: Center(
        child: Icon(Icons.videocam, color: context.colors.textMuted, size: 64),
      ),
    );
  }
}

class _CallControls extends StatelessWidget {
  const _CallControls({
    required this.answered,
    required this.outgoing,
    required this.muted,
    required this.speakerOn,
    required this.onHold,
    this.onToggleMute,
    this.onToggleSpeaker,
    this.onToggleHold,
    this.onReject,
    this.onAnswer,
    this.onCancel,
    this.onEnd,
  });

  final bool answered;
  final bool outgoing;
  final bool muted;
  final bool speakerOn;
  final bool onHold;
  final VoidCallback? onToggleMute;
  final VoidCallback? onToggleSpeaker;
  final VoidCallback? onToggleHold;
  final VoidCallback? onReject;
  final VoidCallback? onAnswer;
  final VoidCallback? onCancel;
  final VoidCallback? onEnd;

  @override
  Widget build(BuildContext context) {
    if (!answered && !outgoing) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _RoundButton(
            icon: Icons.call_end,
            color: context.colors.danger,
            label: 'Отклонить',
            onTap: onReject,
          ),
          _RoundButton(
            icon: Icons.call,
            color: context.colors.success,
            label: 'Ответить',
            onTap: onAnswer,
          ),
        ],
      );
    }
    if (!answered) {
      return Center(
        child: _RoundButton(
          icon: Icons.call_end,
          color: context.colors.danger,
          label: 'Отменить',
          onTap: onCancel,
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: _RoundButton(
            icon: muted ? Icons.mic_off : Icons.mic,
            color: muted
                ? context.colors.warning.withValues(alpha: 0.28)
                : context.colors.surface.withValues(alpha: 0.82),
            label: muted ? 'Вкл. звук' : 'Микрофон',
            onTap: onToggleMute,
          ),
        ),
        Expanded(
          child: _RoundButton(
            icon: speakerOn ? Icons.volume_up : Icons.volume_down,
            color: speakerOn
                ? context.colors.primary.withValues(alpha: 0.42)
                : context.colors.surface.withValues(alpha: 0.82),
            label: speakerOn ? 'Динамик' : 'Тихо',
            onTap: onToggleSpeaker,
          ),
        ),
        Expanded(
          child: _RoundButton(
            icon: onHold ? Icons.play_arrow : Icons.pause,
            color: onHold
                ? context.colors.primary.withValues(alpha: 0.42)
                : context.colors.surface.withValues(alpha: 0.82),
            label: onHold ? 'Продолжить' : 'Удержание',
            onTap: onToggleHold,
          ),
        ),
        Expanded(
          child: _RoundButton(
            icon: Icons.call_end,
            color: context.colors.danger,
            label: 'Завершить',
            onTap: onEnd,
          ),
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.color,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          iconSize: 28,
          padding: const EdgeInsets.all(18),
          style: IconButton.styleFrom(
            backgroundColor: color,
            shape: const CircleBorder(),
          ),
          icon: Icon(icon, color: Colors.white),
          onPressed: onTap,
        ),
        const SizedBox(height: 6),
        Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: AppTypography.caption.copyWith(
            color: Colors.white.withValues(alpha: 0.78),
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}
