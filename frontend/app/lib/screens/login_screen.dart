import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_button.dart';
import '../core/ui/app_search_field.dart';
import '../crypto/auth_keypair.dart';
import '../services/session_store.dart';
import '../state/app_controller.dart';
import 'device_link_qr_screen.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _identifierController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _submit() async {
    final identifier = _identifierController.text.trim();
    final password = _passwordController.text;
    if (identifier.isEmpty || password.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final controller = ref.read(appControllerProvider);
    controller.homeMovedMessage = null;
    try {
      await controller.loginWithPassword(identifier, password);
    } catch (e) {
      setState(() => _error = 'Не удалось войти: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submitLocalKey() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(appControllerProvider).loginWithLocalKey();
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось войти по ключу: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    // Post-R5 client failover (docs/reality/R4-routing.md Gaps): set when
    // failover switched Home but couldn't recover the session there — shown
    // once, then cleared so it doesn't linger across unrelated login errors.
    final homeMovedMessage = ref.watch(appControllerProvider).homeMovedMessage;

    return Scaffold(
      appBar: AppBar(title: const Text('Вход')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 48,
                  color: colors.primary.withValues(alpha: 0.7),
                ),
                const SizedBox(height: AppSpacing.lg),
                if (homeMovedMessage != null) ...[
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: colors.warning.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline,
                          color: colors.warning,
                          size: 20,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(homeMovedMessage, style: text.caption),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                Text('Телефон, логин или email', style: text.secondary),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Первый вход может занять 10–20 сек — генерируются криптоключи.',
                  style: text.caption,
                ),
                const SizedBox(height: AppSpacing.lg),
                FutureBuilder<bool>(
                  future: (() async =>
                      await AuthKeyPair.existsLocally() &&
                      await SessionStore().loadRememberedIdentity() != null)(),
                  builder: (context, snapshot) {
                    if (snapshot.data != true) return const SizedBox.shrink();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AppButton(
                          label: 'Войти по ключу этого устройства',
                          onPressed: _loading ? null : _submitLocalKey,
                          loading: _loading,
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        Row(
                          children: [
                            const Expanded(child: Divider()),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.sm,
                              ),
                              child: Text('или', style: text.caption),
                            ),
                            const Expanded(child: Divider()),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.lg),
                      ],
                    );
                  },
                ),
                AppTextField(
                  controller: _identifierController,
                  hintText: 'Телефон / логин / email',
                ),
                const SizedBox(height: AppSpacing.sm),
                AppTextField(
                  controller: _passwordController,
                  hintText: 'Пароль',
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    _error!,
                    style: text.caption.copyWith(color: colors.danger),
                  ),
                ],
                const SizedBox(height: AppSpacing.lg),
                AppButton(
                  label: 'Войти',
                  onPressed: _loading ? null : _submit,
                  loading: _loading,
                ),
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  label: 'Войти на новом устройстве по QR',
                  onPressed: _loading
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const DeviceLinkQrScreen(),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
