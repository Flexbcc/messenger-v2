import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_button.dart';
import '../core/ui/app_card.dart';
import '../crypto/auth_keypair.dart';
import '../crypto/crypto_service.dart';
import '../services/contact_pairing_payload.dart';
import '../services/settings_runtime.dart';
import '../state/app_controller.dart';

/// One-time signed handshake QR. Personal profile data is never embedded.
class ProfileQrScreen extends ConsumerStatefulWidget {
  const ProfileQrScreen({super.key});

  @override
  ConsumerState<ProfileQrScreen> createState() => _ProfileQrScreenState();
}

class _ProfileQrScreenState extends ConsumerState<ProfileQrScreen> {
  int _ttl = 30;
  String _payload = '';
  DateTime? _expiresAt;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final runtime = SettingsRuntime.instance;
    final app = ref.read(appControllerProvider);
    final ttl = await runtime.qrTtlMinutes();
    final userId = app.session?.userId ?? '';
    final effectiveTtl = ttl.clamp(1, 60);
    final expires = DateTime.now().add(Duration(minutes: effectiveTtl));
    final signer = app.authKeyPair ?? await AuthKeyPair.loadOrCreate();
    final crypto = app.crypto ?? await CryptoService.loadOrCreate();
    final payload = await ContactPairingPayload.create(
      userId: userId,
      signer: signer,
      identityPublicKey: crypto.identityPublicKeyBase64,
      ttl: Duration(minutes: effectiveTtl),
    );
    if (!mounted) return;
    setState(() {
      _ttl = effectiveTtl;
      _expiresAt = expires;
      _payload = payload;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    final colors = context.colors;
    final expired = _expiresAt != null && DateTime.now().isAfter(_expiresAt!);

    return Scaffold(
      appBar: AppBar(title: const Text('QR профиля')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              children: [
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Одноразовый обмен ключами', style: text.subtitle),
                      const SizedBox(height: AppSpacing.sm),
                      Text('TTL: $_ttl мин.', style: text.caption),
                      Text(
                        expired
                            ? 'Истёк — обновите QR'
                            : 'Действует до: ${_expiresAt!.toLocal()}',
                        style: text.caption.copyWith(
                          color: expired ? colors.danger : colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                AppCard(
                  child: Column(
                    children: [
                      Container(
                        color: Colors.white,
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: QrImageView(
                          data: _payload,
                          size: 260,
                          backgroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        'QR содержит только технические данные и публичные ключи. Профиль передаётся позже по зашифрованному каналу.',
                        textAlign: TextAlign.center,
                        style: text.caption,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                AppButton(
                  label: expired ? 'Обновить QR' : 'Копировать payload',
                  onPressed: () async {
                    if (expired) {
                      await _load();
                      return;
                    }
                    await Clipboard.setData(ClipboardData(text: _payload));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('QR payload скопирован')),
                      );
                    }
                  },
                ),
              ],
            ),
    );
  }
}
