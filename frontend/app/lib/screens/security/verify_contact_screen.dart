import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_button.dart';
import '../../core/ui/app_card.dart';
import '../../models/contact_trust.dart';
import '../../services/contact_key_verification_service.dart';
import '../../state/app_controller.dart';

/// Manual verification of every trusted Signal identity key for a contact.
class VerifyContactScreen extends ConsumerStatefulWidget {
  const VerifyContactScreen({
    super.key,
    required this.userId,
    required this.displayName,
    this.targetTrust = TrustLevel.trusted,
  }) : assert(
         targetTrust == TrustLevel.trusted ||
             targetTrust == TrustLevel.highTrust,
       );

  final String userId;
  final String displayName;
  final TrustLevel targetTrust;

  @override
  ConsumerState<VerifyContactScreen> createState() =>
      _VerifyContactScreenState();
}

class _VerifyContactScreenState extends ConsumerState<VerifyContactScreen> {
  final _verification = ContactKeyVerificationService();
  List<ContactDeviceFingerprint>? _devices;
  Object? _error;
  bool _confirmed = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _devices = null;
      _error = null;
      _confirmed = false;
    });
    try {
      final devices = await _verification.load(widget.userId);
      if (!mounted) return;
      setState(() => _devices = devices);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  Future<void> _markTrusted() async {
    if (!_confirmed || _devices == null || _saving) return;
    setState(() => _saving = true);
    try {
      await _verification.recordVerified(widget.userId, _devices!);
      await ref
          .read(appControllerProvider)
          .setContactTrustLevel(widget.userId, widget.targetTrust);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Уровень доверия: ${widget.targetTrust.label}')),
      );
      Navigator.pop(context);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ключи изменились или не удалось сохранить проверку'),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final trust = ref.watch(appControllerProvider).trustLevelFor(widget.userId);
    final devices = _devices;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.displayName),
        actions: [
          IconButton(
            tooltip: 'Обновить ключи',
            onPressed: devices == null ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Отпечатки устройств', style: text.sectionTitle),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Сравните каждый отпечаток с собеседником лично или по уже проверенному каналу. При добавлении устройства проверку нужно повторить.',
                  style: text.caption,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (_error != null)
            AppCard(
              child: Column(
                children: [
                  Icon(Icons.error_outline, color: colors.danger),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Не удалось получить подтверждённые ключи контакта.',
                    style: text.body,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppButton(label: 'Повторить', onPressed: _load),
                ],
              ),
            )
          else if (devices == null)
            const Center(child: CircularProgressIndicator())
          else ...[
            for (final device in devices) ...[
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(device.deviceName, style: text.subtitle),
                    const SizedBox(height: 2),
                    Text(device.deviceType, style: text.caption),
                    const SizedBox(height: AppSpacing.sm),
                    SelectableText(
                      device.fingerprint,
                      style: text.body.copyWith(
                        fontFamily: 'monospace',
                        color: colors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            if (trust.index < TrustLevel.trusted.index)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _confirmed,
                onChanged: (value) =>
                    setState(() => _confirmed = value == true),
                title: const Text('Я сравнил все показанные отпечатки'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
          ],
          const SizedBox(height: AppSpacing.lg),
          if (trust.index < TrustLevel.trusted.index)
            AppButton(
              label: widget.targetTrust == TrustLevel.highTrust
                  ? 'Подтвердить высокий уровень доверия'
                  : 'Отметить как доверенный',
              loading: _saving,
              onPressed: devices != null && _confirmed && !_saving
                  ? _markTrusted
                  : null,
            )
          else
            AppButton(
              label: 'Уже доверенный контакт',
              variant: AppButtonVariant.secondary,
              onPressed: null,
            ),
        ],
      ),
    );
  }
}
