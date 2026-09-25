import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/theme/app_spacing.dart';
import '../core/ui/app_page.dart';
import '../services/node_owner/node_owner_pairing_payload.dart';
import '../services/qr_image_decoder.dart';

class NodeOwnerPairingScannerScreen extends StatefulWidget {
  const NodeOwnerPairingScannerScreen({super.key});

  @override
  State<NodeOwnerPairingScannerScreen> createState() =>
      _NodeOwnerPairingScannerScreenState();
}

class _NodeOwnerPairingScannerScreenState
    extends State<NodeOwnerPairingScannerScreen> {
  final _scanner = MobileScannerController();
  bool _handling = false;
  String? _error;

  Future<void> _pickQrImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: false,
    );
    final bytes = result?.files.single.bytes;
    if (bytes == null || bytes.isEmpty) return;
    try {
      await _handle(decodeQrImage(bytes));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _handle(String raw) async {
    if (_handling) return;
    _handling = true;
    await _scanner.stop();
    try {
      final pairing = NodeOwnerPairingPayload.parse(raw);
      if (mounted) Navigator.of(context).pop(pairing);
      return;
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
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
    return AppPage(
      title: 'Подключение ноды',
      scroll: false,
      child: Column(
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
                  'Отсканируйте одноразовый QR, созданный командой ouoctl на вашей ноде. QR действует не более 10 минут.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton.icon(
                  onPressed: _handling ? null : _pickQrImage,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Выбрать QR из файла'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
