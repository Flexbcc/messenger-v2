import 'package:flutter/material.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_button.dart';
import '../core/ui/app_search_field.dart';
import '../services/bootstrap_service.dart';

/// Connect client to a cluster via one-time invite link (QR payload).
class JoinNetworkScreen extends StatefulWidget {
  const JoinNetworkScreen({super.key, this.onJoined});

  final VoidCallback? onJoined;

  @override
  State<JoinNetworkScreen> createState() => _JoinNetworkScreenState();
}

class _JoinNetworkScreenState extends State<JoinNetworkScreen> {
  final _linkController = TextEditingController();
  bool _loading = false;
  String? _error;
  String? _success;

  Future<void> _submit() async {
    final parsed = BootstrapService.parseInviteLink(_linkController.text);
    if (parsed == null) {
      setState(() {
        _error = 'Вставьте ссылку вида https://gateway/join?t=...';
        _success = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _success = null;
    });
    try {
      final bootstrap = await BootstrapService.redeemInvite(
        gatewayUrl: parsed.gatewayUrl,
        token: parsed.token,
      );
      await BootstrapStore.save(bootstrap);
      setState(() {
        _success =
            'Подключено к кластеру «${bootstrap.clusterId}»\nHome: ${bootstrap.homeUrl}';
      });
      widget.onJoined?.call();
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Подключиться к сети'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Закрыть',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.hub_outlined, size: 56, color: colors.primary),
                  const SizedBox(height: AppSpacing.lg),
                  Text('Подключиться к сети', style: text.largeTitle),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Вставьте одноразовую ссылку или QR-код от оператора ноды. '
                    'Без своей ноды вы регистрируетесь на Home оператора.',
                    style: text.secondary,
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  AppTextField(
                    controller: _linkController,
                    hintText: 'https://…/join?t=…',
                    maxLines: 3,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppButton(
                    label: _loading ? 'Подключение…' : 'Подключить',
                    onPressed: _loading ? null : _submit,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    Text(_error!, style: text.caption.copyWith(color: colors.danger)),
                  ],
                  if (_success != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    Text(_success!, style: text.caption.copyWith(color: colors.success)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
