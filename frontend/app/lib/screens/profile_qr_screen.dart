import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_button.dart';
import '../core/ui/app_card.dart';
import '../services/settings_runtime.dart';
import '../state/app_controller.dart';

/// Profile QR payload with mode + TTL from catalog privacy.qr_* settings.
class ProfileQrScreen extends ConsumerStatefulWidget {
  const ProfileQrScreen({super.key});

  @override
  ConsumerState<ProfileQrScreen> createState() => _ProfileQrScreenState();
}

class _ProfileQrScreenState extends ConsumerState<ProfileQrScreen> {
  String _mode = 'temporary';
  int _ttl = 30;
  bool _qrOnly = false;
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
    final mode = await runtime.qrMode();
    final ttl = await runtime.qrTtlMinutes();
    final qrOnly = await runtime.qrOnlyMode();
    final userId = app.session?.userId ?? '';
    final expires = mode == 'permanent'
        ? null
        : DateTime.now().add(Duration(minutes: ttl.clamp(1, 10080)));
    final map = {
      'v': 1,
      'user_id': userId,
      'display_name': app.session?.displayName ?? '',
      'qr_mode': mode,
      if (expires != null) 'expires_at': expires.toIso8601String(),
      if (mode == 'single_use') 'nonce': DateTime.now().millisecondsSinceEpoch,
    };
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _ttl = ttl;
      _qrOnly = qrOnly;
      _expiresAt = expires;
      _payload = const JsonEncoder.withIndent('  ').convert(map);
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
                      Text('Режим: $_mode', style: text.subtitle),
                      const SizedBox(height: AppSpacing.sm),
                      if (_mode == 'temporary')
                        Text('TTL: $_ttl мин.', style: text.caption),
                      if (_expiresAt != null)
                        Text(
                          expired
                              ? 'Истёк — обновите QR'
                              : 'Действует до: ${_expiresAt!.toLocal()}',
                          style: text.caption.copyWith(
                            color: expired
                                ? colors.danger
                                : colors.textSecondary,
                          ),
                        ),
                      if (_qrOnly) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          'QR-only: телефон и email не включаются в обычный шаринг профиля.',
                          style: text.caption,
                        ),
                      ],
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
                        'Покажите этот QR собеседнику. ID и имя будут заполнены автоматически.',
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
