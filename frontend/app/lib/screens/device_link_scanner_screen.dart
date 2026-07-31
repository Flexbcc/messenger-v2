import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/theme/app_spacing.dart';
import '../state/app_controller.dart';

/// Trusted device: scans and explicitly approves a new phone/PC.
class DeviceLinkScannerScreen extends ConsumerStatefulWidget {
  const DeviceLinkScannerScreen({super.key});

  @override
  ConsumerState<DeviceLinkScannerScreen> createState() =>
      _DeviceLinkScannerScreenState();
}

class _DeviceLinkScannerScreenState
    extends ConsumerState<DeviceLinkScannerScreen> {
  final _scanner = MobileScannerController();
  bool _handling = false;
  String? _error;

  Future<void> _handle(String raw) async {
    if (_handling) return;
    _handling = true;
    await _scanner.stop();
    try {
      final controller = ref.read(appControllerProvider);
      final preview = await controller.inspectDeviceLinkPayload(raw);
      if (!mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Подключить устройство?'),
          content: Text(
            '${preview['device_name']}\n'
            'Тип: ${preview['device_type']}\n\n'
            'Устройство получит доступ к этому аккаунту.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Подключить'),
            ),
          ],
        ),
      );
      if (approved == true) {
        await controller.approveDeviceLinkPayload(raw);
        if (mounted) Navigator.of(context).pop(true);
        return;
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
    _handling = false;
    await _scanner.start();
  }

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Сканировать устройство')),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _scanner,
              onDetect: (capture) {
                for (final barcode in capture.barcodes) {
                  final raw = barcode.rawValue;
                  if (raw != null && raw.isNotEmpty) {
                    _handle(raw);
                    break;
                  }
                }
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              children: [
                const Text(
                  'Сканируйте QR, который показывает новый телефон или ПК.',
                  textAlign: TextAlign.center,
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(_error!, textAlign: TextAlign.center),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
