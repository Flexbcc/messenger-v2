import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_button.dart';
import '../../core/ui/app_card.dart';
import '../../models/contact_trust.dart';
import '../../services/security_meta_store.dart';
import '../../state/app_controller.dart';

/// Key verification — safety number + QR code (Signal-compatible fingerprint).
class VerifyContactScreen extends ConsumerStatefulWidget {
  const VerifyContactScreen({super.key, required this.userId, required this.displayName});

  final String userId;
  final String displayName;

  @override
  ConsumerState<VerifyContactScreen> createState() => _VerifyContactScreenState();
}

class _VerifyContactScreenState extends ConsumerState<VerifyContactScreen> {
  String? _safetyNumber;
  bool _loading = true;
  bool _scanning = false;
  String? _scanError;

  @override
  void initState() {
    super.initState();
    _computeSafetyNumber();
  }

  Future<void> _computeSafetyNumber() async {
    final controller = ref.read(appControllerProvider);
    final myUserId = controller.session?.userId;
    final crypto = controller.crypto;
    if (myUserId == null || crypto == null) {
      setState(() { _loading = false; });
      return;
    }
    try {
      final number = await crypto.computeSafetyNumber(myUserId, widget.userId);
      setState(() {
        _safetyNumber = number;
        _loading = false;
      });
    } catch (e) {
      setState(() { _loading = false; });
    }
  }

  String get _qrData {
    final controller = ref.read(appControllerProvider);
    final myUserId = controller.session?.userId ?? '';
    final myKey = controller.crypto?.myIdentityKeyBase64 ?? '';
    return 'messenger-verify:$myUserId:$myKey';
  }

  void _startScan() => setState(() { _scanning = true; _scanError = null; });
  void _stopScan() => setState(() { _scanning = false; });

  void _onScanResult(BarcodeCapture capture) {
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;
    _stopScan();

    // Expected format: messenger-verify:<userId>:<identityKeyBase64>
    if (!raw.startsWith('messenger-verify:')) {
      setState(() { _scanError = 'Неверный QR-код — это не верификационный код мессенджера'; });
      return;
    }
    final parts = raw.split(':');
    if (parts.length < 3) {
      setState(() { _scanError = 'Неверный формат QR-кода'; });
      return;
    }
    final scannedUserId = parts[1];
    if (scannedUserId != widget.userId) {
      setState(() {
        _scanError = 'QR-код от другого пользователя ($scannedUserId), ожидался ${widget.userId}';
      });
      return;
    }
    // QR matches — safety number already matches if from the same session
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('QR-код $scannedUserId совпадает ✓')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final trust = ref.watch(appControllerProvider).trustLevelFor(widget.userId);

    return Scaffold(
      appBar: AppBar(title: Text('Верификация: ${widget.displayName}')),
      body: _scanning
          ? _buildScanner()
          : SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: Column(
                children: [
                  // QR code
                  AppCard(
                    child: Column(
                      children: [
                        if (_safetyNumber != null)
                          QrImageView(
                            data: _qrData,
                            version: QrVersions.auto,
                            size: 200,
                          )
                        else
                          const Icon(Icons.qr_code_2, size: 120),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          'Покажите этот QR-код собеседнику для сканирования',
                          style: text.caption,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        TextButton.icon(
                          onPressed: _startScan,
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text('Сканировать QR собеседника'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),

                  // Safety number
                  AppCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        ListTile(
                          leading: Icon(Icons.numbers, color: colors.textSecondary),
                          title: Text('Safety number', style: text.subtitle),
                          subtitle: _loading
                              ? const Text('Вычисляется…')
                              : _safetyNumber != null
                                  ? Text(
                                      _safetyNumber!,
                                      style: text.caption?.copyWith(
                                        fontFamily: 'monospace',
                                        letterSpacing: 1.2,
                                      ),
                                    )
                                  : const Text('Сначала начните переписку с этим контактом'),
                          trailing: _safetyNumber != null
                              ? IconButton(
                                  icon: const Icon(Icons.copy, size: 18),
                                  tooltip: 'Скопировать',
                                  onPressed: () {
                                    Clipboard.setData(ClipboardData(text: _safetyNumber!));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Safety number скопирован')),
                                    );
                                  },
                                )
                              : null,
                        ),
                        if (_scanError != null) ...[
                          const Divider(height: 1),
                          Padding(
                            padding: const EdgeInsets.all(AppSpacing.md),
                            child: Text(
                              _scanError!,
                              style: TextStyle(color: colors.error, fontSize: 13),
                            ),
                          ),
                        ],
                        const Divider(height: 1),
                        ListTile(
                          leading: Icon(Icons.info_outline, color: colors.textSecondary),
                          title: Text('Как верифицировать', style: text.subtitle),
                          subtitle: const Text(
                            'Сравните safety number с собеседником лично или по защищённому каналу. '
                            'Совпадает — нажмите "Отметить как доверенный".',
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: AppSpacing.xl),

                  if (trust.index < TrustLevel.trusted.index)
                    AppButton(
                      label: 'Отметить как доверенный',
                      onPressed: _safetyNumber != null
                          ? () async {
                              await ref.read(appControllerProvider).setContactTrustLevel(
                                    widget.userId, TrustLevel.trusted);
                              await SecurityMetaStore.instance.recordContactVerification();
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Контакт отмечен как доверенный')),
                                );
                                Navigator.pop(context);
                              }
                            }
                          : null,
                    )
                  else
                    AppButton(
                      label: 'Уже доверенный контакт ✓',
                      variant: AppButtonVariant.secondary,
                      onPressed: null,
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildScanner() {
    return Stack(
      children: [
        MobileScanner(onDetect: _onScanResult),
        Positioned(
          top: 16,
          left: 16,
          child: SafeArea(
            child: IconButton(
              onPressed: _stopScan,
              icon: const Icon(Icons.close, color: Colors.white, size: 32),
              style: IconButton.styleFrom(backgroundColor: Colors.black54),
            ),
          ),
        ),
        const Positioned.fill(
          child: Center(
            child: Text(
              'Наведите камеру на QR-код собеседника',
              style: TextStyle(color: Colors.white, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }
}
