import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';

/// Результат успешного сканирования QR профиля.
class QrProfilePayload {
  const QrProfilePayload({
    required this.userId,
    required this.displayName,
    required this.qrMode,
    this.expiresAt,
    this.nonce,
  });

  final String userId;
  final String displayName;
  final String qrMode;       // 'temporary' | 'permanent' | 'single_use'
  final DateTime? expiresAt;
  final int? nonce;          // single_use guard

  /// Парсит QR payload мессенджера. Возвращает null если формат не наш.
  static QrProfilePayload? tryParse(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      // Обязательные поля
      if (map['v'] != 1) return null;
      final userId = map['user_id'] as String?;
      if (userId == null || userId.isEmpty) return null;

      final expiresRaw = map['expires_at'] as String?;
      final expiresAt = expiresRaw != null ? DateTime.tryParse(expiresRaw) : null;

      // Проверка TTL — истёкший QR отклоняем
      if (expiresAt != null && DateTime.now().isAfter(expiresAt)) return null;

      return QrProfilePayload(
        userId: userId,
        displayName: map['display_name'] as String? ?? userId,
        qrMode: map['qr_mode'] as String? ?? 'temporary',
        expiresAt: expiresAt,
        nonce: map['nonce'] as int?,
      );
    } catch (_) {
      return null;
    }
  }

  bool get isExpired =>
      expiresAt != null && DateTime.now().isAfter(expiresAt!);
}

/// Полноэкранный QR-сканер. Возвращает [QrProfilePayload] при успехе
/// или null если пользователь закрыл экран.
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  /// Открыть сканер и вернуть результат.
  static Future<QrProfilePayload?> open(BuildContext context) {
    return Navigator.of(context).push<QrProfilePayload?>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
  }

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );

  bool _processing = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_processing) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final payload = QrProfilePayload.tryParse(raw);
      if (payload != null) {
        _processing = true;
        Navigator.of(context).pop(payload);
        return;
      }
    }
    // Сканируем QR, но формат не наш
    if (!_processing) {
      setState(() => _error = 'QR не распознан как контакт мессенджера');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Сканировать QR'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(null),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on_outlined),
            tooltip: 'Вспышка',
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Камера на весь экран
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),

          // Рамка прицела
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: colors.primary, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),

          // Подсказка снизу
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.xl),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: text.caption.copyWith(color: Colors.orangeAccent),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  Text(
                    'Наведите камеру на QR-код собеседника',
                    style: text.secondary.copyWith(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'QR действует только при личном присутствии',
                    style: text.caption.copyWith(color: Colors.white38),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
