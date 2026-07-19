// QR-код для pairing (сканирование с ноды / телефона).
library;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/storage_service.dart';

class PairingQrCard extends StatelessWidget {
  const PairingQrCard({
    super.key,
    required this.service,
    required this.lanHosts,
  });

  final StorageService service;
  final List<String> lanHosts;

  @override
  Widget build(BuildContext context) {
    final code = service.activePairCode;
    if (code == null) return const SizedBox.shrink();

    final payload = service.pairingPayloadJson(lanHosts);
    if (payload == null) return const SizedBox.shrink();

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: QrImageView(
            data: payload,
            version: QrVersions.auto,
            size: 180,
            backgroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Отсканируйте QR на ноде или вставьте JSON вручную',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
