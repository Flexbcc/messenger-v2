import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/theme/app_spacing.dart';
import '../state/app_controller.dart';

/// New device: displays a one-time QR and waits for any trusted device.
class DeviceLinkQrScreen extends ConsumerStatefulWidget {
  const DeviceLinkQrScreen({super.key});

  @override
  ConsumerState<DeviceLinkQrScreen> createState() => _DeviceLinkQrScreenState();
}

class _DeviceLinkQrScreenState extends ConsumerState<DeviceLinkQrScreen> {
  Map<String, dynamic>? _link;
  Timer? _timer;
  String? _error;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _create();
  }

  Future<void> _create() async {
    _timer?.cancel();
    setState(() {
      _link = null;
      _error = null;
    });
    try {
      final link = await ref.read(appControllerProvider).createDeviceLink();
      if (!mounted) return;
      setState(() => _link = link);
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _poll() async {
    final link = _link;
    if (_polling || link == null) return;
    _polling = true;
    try {
      final done = await ref
          .read(appControllerProvider)
          .pollDeviceLink(link['link_id'] as String, link['secret'] as String);
      if (done) {
        _timer?.cancel();
        if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      _timer?.cancel();
      if (mounted) setState(() => _error = e.toString());
    } finally {
      _polling = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final link = _link;
    return Scaffold(
      appBar: AppBar(title: const Text('Вход по QR')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Откройте OUO на уже авторизованном устройстве: '
                  'Настройки → Устройства → Сканировать QR.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.xl),
                if (link == null && _error == null)
                  const CircularProgressIndicator()
                else if (link != null)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: QrImageView(
                        data: link['qr_payload'] as String,
                        size: 260,
                      ),
                    ),
                  ),
                if (_error != null) ...[
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: AppSpacing.md),
                  FilledButton(
                    onPressed: _create,
                    child: const Text('Создать новый QR'),
                  ),
                ] else if (link != null) ...[
                  const SizedBox(height: AppSpacing.lg),
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: AppSpacing.sm),
                      Text('Ожидаем подтверждение…'),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  const Text('Код действует 5 минут'),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
