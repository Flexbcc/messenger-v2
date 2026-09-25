import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../calls/active_call.dart';
import '../core/extensions/context_extensions.dart';
import '../calls/call_signal.dart';
import '../state/app_controller.dart';
import '../utils/call_format.dart';

/// Draggable floating bubble shown when the user minimizes the full-screen call.
class CallMinimizedBar extends ConsumerStatefulWidget {
  const CallMinimizedBar({super.key});

  @override
  ConsumerState<CallMinimizedBar> createState() => _CallMinimizedBarState();
}

class _CallMinimizedBarState extends ConsumerState<CallMinimizedBar>
    with SingleTickerProviderStateMixin {
  Timer? _timer;
  Offset _position = const Offset(double.infinity, double.infinity);
  bool _positioned = false;
  late AnimationController _pulseCtrl;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulse = Tween<double>(
      begin: 0.92,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  String _status(ActiveCall call) {
    if (!call.answered) return call.outgoing ? 'Звоним…' : 'Входящий';
    if (call.waitingForNetwork) return '…';
    if (call.media?.onHold == true) return '⏸';
    return formatCallDuration(_elapsed(call));
  }

  Duration _elapsed(ActiveCall call) {
    final start = call.answeredAt ?? call.startedAt;
    return DateTime.now().difference(start);
  }

  String _initials(String name) {
    final parts = name.trim().split(' ');
    return parts
        .map((w) => w.isNotEmpty ? w[0] : '')
        .take(2)
        .join()
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final call = controller.currentCall;
    if (call == null) return const SizedBox.shrink();

    final peerName = controller.labelFor(call.peerUserId);
    final size = MediaQuery.of(context).size;
    final top = MediaQuery.of(context).padding.top;

    // Начальная позиция — правый верхний угол
    if (!_positioned) {
      _position = Offset(size.width - 96, top + 16);
      _positioned = true;
    }

    final colors = context.colors;
    final bubbleColor = colors.primary;
    final status = _status(call);
    final isActive =
        call.answered && call.media?.onHold != true && !call.waitingForNetwork;

    return Positioned(
      left: _position.dx,
      top: _position.dy,
      child: GestureDetector(
        onPanUpdate: (d) {
          setState(() {
            _position = Offset(
              (_position.dx + d.delta.dx).clamp(0, size.width - 80),
              (_position.dy + d.delta.dy).clamp(top, size.height - 160),
            );
          });
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Пузырь с аватаром
            GestureDetector(
              onTap: () => controller.setCallUiMinimized(false),
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (context, child) => Transform.scale(
                  scale: isActive ? _pulse.value : 1.0,
                  child: child,
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Кольцо пульсации
                    if (isActive)
                      AnimatedBuilder(
                        animation: _pulse,
                        builder: (_, __) => Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: bubbleColor.withValues(
                              alpha: (1 - _pulse.value) * 0.4,
                            ),
                          ),
                        ),
                      ),
                    // Основной круг
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [bubbleColor, colors.secondary],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: bubbleColor.withValues(alpha: 0.45),
                            blurRadius: 16,
                            spreadRadius: 2,
                          ),
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _initials(peerName),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            status,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 9,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Иконка типа звонка — маленький бейдж
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: colors.surface,
                        ),
                        child: Icon(
                          call.kind == CallKind.video
                              ? Icons.videocam
                              : Icons.mic,
                          color: Colors.white,
                          size: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            // Кнопка завершить
            GestureDetector(
              onTap: call.answered
                  ? controller.endCall
                  : (call.outgoing
                        ? controller.cancelCall
                        : controller.rejectCall),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: context.colors.danger,
                  boxShadow: [
                    BoxShadow(
                      color: context.colors.danger.withValues(alpha: 0.4),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.call_end,
                  color: Colors.white,
                  size: 18,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
