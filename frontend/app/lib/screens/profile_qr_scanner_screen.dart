import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/theme/app_spacing.dart';
import '../utils/user_id.dart';

class ProfileQrResult {
  const ProfileQrResult({required this.userId, required this.displayName});

  final String userId;
  final String displayName;
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

  Future<void> _handle(String raw) async {
    if (_handling) return;
    _handling = true;
    await _scanner.stop();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> || decoded['v'] != 1) {
        throw const FormatException('Это не QR профиля мессенджера');
      }
      final userId = normalizeUserId(decoded['user_id']?.toString() ?? '');
      if (!isValidUserIdFormat(userId)) {
        throw const FormatException('В QR указан некорректный User ID');
      }
      final expiresRaw = decoded['expires_at']?.toString();
      if (expiresRaw != null && expiresRaw.isNotEmpty) {
        final expiresAt = DateTime.tryParse(expiresRaw);
        if (expiresAt == null || DateTime.now().isAfter(expiresAt)) {
          throw const FormatException('Срок действия QR истёк');
        }
      }
      final displayName = decoded['display_name']?.toString().trim() ?? '';
      if (mounted) {
        Navigator.of(
          context,
        ).pop(ProfileQrResult(userId: userId, displayName: displayName));
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
                  'Наведите камеру на QR профиля собеседника.',
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
