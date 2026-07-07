import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_button.dart';
import '../core/ui/app_search_field.dart';
import '../state/app_controller.dart';

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
    try {
      await ref.read(appControllerProvider).loginWithPassword(identifier, password);
    } catch (e) {
      setState(() => _error = 'Не удалось войти: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

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
                Icon(Icons.lock_outline, size: 48, color: colors.primary.withValues(alpha: 0.7)),
                const SizedBox(height: AppSpacing.lg),
                Text('Телефон, логин или email', style: text.secondary),
                const SizedBox(height: AppSpacing.sm),
                Text('Первый вход может занять 10–20 сек — генерируются криптоключи.', style: text.caption),
                const SizedBox(height: AppSpacing.lg),
                AppTextField(controller: _identifierController, hintText: 'Телефон / логин / email'),
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
                  Text(_error!, style: text.caption.copyWith(color: colors.danger)),
                ],
                const SizedBox(height: AppSpacing.lg),
                AppButton(label: 'Войти', onPressed: _loading ? null : _submit, loading: _loading),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
