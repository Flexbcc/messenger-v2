import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/theme/app_spacing.dart';
import '../services/contact_pairing_payload.dart';
import '../services/qr_image_decoder.dart';

class ProfileQrResult {
  const ProfileQrResult({required this.handshake});

  final ContactPairingPayload handshake;
  String get userId => handshake.userId;
}

/// Scans the JSON produced by [ProfileQrScreen] and returns a verified peer.
class ProfileQrScannerScreen extends StatefulWidget {
  const ProfileQrScannerScreen({super.key});

  @override
  State<ProfileQrScannerScreen> createState() => _ProfileQrScannerScreenState();
}

class _ProfileQrScannerScreenState extends State<ProfileQrScannerScreen> {
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
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _handle(String raw) async {
    if (_handling) return;
    _handling = true;
    await _scanner.stop();
    try {
      final handshake = await ContactPairingPayload.parseAndVerify(raw);
      if (mounted) {
        Navigator.of(context).pop(ProfileQrResult(handshake: handshake));
      }
      return;
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
      appBar: AppBar(title: const Text('QR собеседника')),
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
                  'Наведите камеру на одноразовый QR обмена ключами.',
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
