import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/dev_screen_capture.dart';

/// Global shortcuts for collecting UI screenshots (including scrolled content).
///
/// - **⌘⇧S** (Ctrl⇧S) — full page (stitches scroll)
/// - **⌘⇧⌥S** (Ctrl⇧AltS) — visible viewport only
///
/// Uses [HardwareKeyboard] so shortcuts work even when a TextField is focused.
class DevScreenCaptureHost extends StatefulWidget {
  const DevScreenCaptureHost({super.key, required this.child});

  final Widget child;

  @override
  State<DevScreenCaptureHost> createState() => _DevScreenCaptureHostState();
}

class _DevScreenCaptureHostState extends State<DevScreenCaptureHost> {
  final _boundaryKey = GlobalKey();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (!kReleaseMode) {
      HardwareKeyboard.instance.addHandler(_onKey);
    }
  }

  @override
  void dispose() {
    if (!kReleaseMode) {
      HardwareKeyboard.instance.removeHandler(_onKey);
    }
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final isMeta = HardwareKeyboard.instance.isMetaPressed;
    final isControl = HardwareKeyboard.instance.isControlPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final isAlt = HardwareKeyboard.instance.isAltPressed;
    final isS = event.logicalKey == LogicalKeyboardKey.keyS;
    if (!isS || !isShift) return false;

    final mac = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    final modOk = mac ? isMeta : isControl;
    if (!modOk) return false;

    _run(fullScroll: !isAlt);
    return true; // consume
  }

  Future<void> _run({required bool fullScroll}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final file = fullScroll
          ? await DevScreenCapture.captureFullScroll(_boundaryKey)
          : await DevScreenCapture.captureViewport(_boundaryKey);
      if (!mounted) return;
      if (file == null) {
        _toast('Не удалось сделать скриншот');
        return;
      }
      await Clipboard.setData(ClipboardData(text: file.path));
      await DevScreenCapture.revealInFileManager(file);
      _toast(fullScroll ? 'Полный экран → ${file.path}' : 'Viewport → ${file.path}');
      debugPrint('DevScreenCapture saved: ${file.path}');
    } catch (e, st) {
      debugPrint('DevScreenCapture failed: $e\n$st');
      if (mounted) _toast('Ошибка скриншота: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      debugPrint(message);
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, maxLines: 4),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    if (kReleaseMode) return widget.child;

    return Stack(
      children: [
        RepaintBoundary(
          key: _boundaryKey,
          child: widget.child,
        ),
        if (_busy)
          const Positioned(
            right: 16,
            bottom: 16,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.all(Radius.circular(20)),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('Скриншот…', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
