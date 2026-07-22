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

/// Экран QR-профиля. Показывает реальный QR-код для сканирования собеседником.
/// Payload формируется по настройкам privacy.qr_* из каталога.
class ProfileQrScreen extends ConsumerStatefulWidget {
  const ProfileQrScreen({super.key});

  @override
  ConsumerState<ProfileQrScreen> createState() => _ProfileQrScreenState();
}

class _ProfileQrScreenState extends ConsumerState<ProfileQrScreen> {
  String _mode = 'temporary';
  int _ttl = 30;
  bool _qrOnly = false;
  Map<String, dynamic> _payloadMap = {};
  String _payloadJson = '';
  DateTime? _expiresAt;
  bool _loading = true;
  Timer? _expiryTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    _expiryTimer?.cancel();

    final runtime = SettingsRuntime.instance;
    final app = ref.read(appControllerProvider);
    final mode = await runtime.qrMode();
    final ttl = await runtime.qrTtlMinutes();
    final qrOnly = await runtime.qrOnlyMode();
    final userId = app.session?.userId ?? '';
    final displayName = app.session?.displayName ?? '';

    final expires = mode == 'permanent'
        ? null
        : DateTime.now().add(Duration(minutes: ttl.clamp(1, 10080)));

    final map = <String, dynamic>{
      'v': 1,
      'user_id': userId,
      'display_name': displayName,
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
      _payloadMap = map;
      _payloadJson = jsonEncode(map);
      _loading = false;
    });

    // Автообновление когда TTL истекает
    if (expires != null) {
      final remaining = expires.difference(DateTime.now());
      if (remaining > Duration.zero) {
        _expiryTimer = Timer(remaining, () {
          if (mounted) setState(() {}); // Перерисовать с меткой «истёк»
        });
      }
    }
  }

  bool get _isExpired =>
      _expiresAt != null && DateTime.now().isAfter(_expiresAt!);

  String _formatExpiry() {
    final exp = _expiresAt;
    if (exp == null) return 'Постоянный';
    if (_isExpired) return 'Истёк — обновите QR';
    final diff = exp.difference(DateTime.now());
    if (diff.inMinutes >= 1) return 'Действует ещё ~${diff.inMinutes} мин.';
    return 'Действует ещё ${diff.inSeconds} сек.';
  }

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    final colors = context.colors;

    return Scaffold(
      appBar: AppBar(title: const Text('Мой QR')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              children: [
                // ── QR-код ────────────────────────────────────────────────
                AppCard(
                  child: Column(
                    children: [
                      const SizedBox(height: AppSpacing.sm),
                      if (_isExpired)
                        Container(
                          width: 260,
                          height: 260,
                          decoration: BoxDecoration(
                            color: colors.surfaceVariant,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.refresh, size: 48, color: colors.textSecondary),
                                const SizedBox(height: AppSpacing.sm),
                                Text('QR истёк', style: text.secondary),
                              ],
                            ),
                          ),
                        )
                      else
                        QrImageView(
                          data: _payloadJson,
                          version: QrVersions.auto,
                          size: 260,
                          backgroundColor: Colors.white,
                          padding: const EdgeInsets.all(12),
                          errorCorrectionLevel: QrErrorCorrectLevel.M,
                        ),
                      const SizedBox(height: AppSpacing.md),

                      // Режим и TTL
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _mode == 'permanent'
                                ? Icons.all_inclusive
                                : _mode == 'single_use'
                                    ? Icons.looks_one_outlined
                                    : Icons.timer_outlined,
                            size: 16,
                            color: _isExpired ? colors.danger : colors.textSecondary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _formatExpiry(),
                            style: text.caption.copyWith(
                              color: _isExpired ? colors.danger : colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                      if (_qrOnly) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          'QR-only: телефон и email не раскрываются',
                          style: text.caption.copyWith(color: colors.textSecondary),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: AppSpacing.sm),
                    ],
                  ),
                ),

                const SizedBox(height: AppSpacing.md),

                // ── Действия ─────────────────────────────────────────────
                Row(
                  children: [
                    Expanded(
                      child: AppButton(
                        label: _isExpired ? 'Обновить QR' : 'Обновить',
                        onPressed: _load,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: AppButton(
                        label: 'Копировать',
                        variant: AppButtonVariant.secondary,
                        onPressed: _isExpired
                            ? null
                            : () async {
                                await Clipboard.setData(
                                  ClipboardData(text: _payloadJson),
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('QR payload скопирован')),
                                  );
                                }
                              },
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: AppSpacing.xl),

                // ── Подсказка ─────────────────────────────────────────────
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline, size: 18, color: colors.primary),
                          const SizedBox(width: AppSpacing.sm),
                          Text('Как это работает', style: text.subtitle),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'Покажите этот QR собеседнику при личной встрече. '
                        'Он сканирует его через «Новый чат → Сканировать QR» '
                        'и связь устанавливается без передачи телефона или имени.',
                        style: text.caption,
                      ),
                      if (_mode == 'temporary') ...[
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          'Режим «временный»: QR действует $_ttl мин. '
                          'Нажмите «Обновить» чтобы сгенерировать новый.',
                          style: text.caption.copyWith(color: colors.textSecondary),
                        ),
                      ],
                      if (_mode == 'single_use') ...[
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          'Режим «одноразовый»: QR можно использовать только один раз.',
                          style: text.caption.copyWith(color: colors.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ),

                // ── Dev: raw payload ──────────────────────────────────────
                if (_payloadMap.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.lg),
                  ExpansionTile(
                    title: Text('Raw payload', style: text.caption),
                    tilePadding: EdgeInsets.zero,
                    children: [
                      AppCard(
                        child: SelectableText(
                          const JsonEncoder.withIndent('  ').convert(_payloadMap),
                          style: text.body.copyWith(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }
}
