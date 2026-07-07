import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_button.dart';
import '../core/ui/app_search_field.dart';
import '../state/app_controller.dart';
import 'join_network_screen.dart';
import 'login_screen.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _loginController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    final password = _passwordController.text;
    if (name.isEmpty || phone.isEmpty || password.isEmpty) {
      setState(() => _error = 'Имя, телефон и пароль обязательны');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(appControllerProvider).register(
            displayName: name,
            phone: phone,
            login: _loginController.text.trim().isEmpty ? null : _loginController.text.trim(),
            email: _emailController.text.trim().isEmpty ? null : _emailController.text.trim(),
            password: password,
          );
    } catch (e) {
      setState(() => _error = 'Не удалось создать аккаунт: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.shield_outlined, size: 64, color: colors.primary),
                  const SizedBox(height: AppSpacing.lg),
                  Text('Создать аккаунт', textAlign: TextAlign.center, style: text.largeTitle),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Приватная переписка со сквозным шифрованием.',
                    textAlign: TextAlign.center,
                    style: text.secondary,
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  AppTextField(controller: _nameController, hintText: 'Имя', autofocus: true),
                  const SizedBox(height: AppSpacing.sm),
                  AppTextField(controller: _phoneController, hintText: 'Телефон', keyboardType: TextInputType.phone),
                  const SizedBox(height: AppSpacing.sm),
                  AppTextField(controller: _loginController, hintText: 'Логин (необязательно)'),
                  const SizedBox(height: AppSpacing.sm),
                  AppTextField(controller: _emailController, hintText: 'Email (необязательно)', keyboardType: TextInputType.emailAddress),
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
                  AppButton(label: 'Продолжить', onPressed: _loading ? null : _submit, loading: _loading),
                  const SizedBox(height: AppSpacing.md),
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => JoinNetworkScreen(
                                  onJoined: () => Navigator.of(context).pop(),
                                ),
                              ),
                            ),
                    child: Text('Подключиться к сети (QR / ссылка)', style: TextStyle(color: colors.primary)),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen())),
                    child: Text('У меня уже есть аккаунт', style: TextStyle(color: colors.primary)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
