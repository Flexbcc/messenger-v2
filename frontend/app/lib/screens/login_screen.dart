import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_button.dart';
import '../core/ui/app_form_body.dart';
import '../core/ui/app_notice.dart';
import '../core/ui/app_search_field.dart';
import '../crypto/auth_keypair.dart';
import '../config.dart';
import '../services/backup_crypto.dart';
import '../services/local_identity_backup.dart';
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
  bool _passwordVisible = false;
  String? _error;

  @override
  void dispose() {
    _identifierController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

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
    } catch (_) {
      setState(
        () =>
            _error = 'Не удалось войти. Проверьте данные и подключение к сети.',
      );
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
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Защищённый вход не выполнен. Проверьте доступность домашней ноды.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _restoreEncryptedBackup() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final bytes = result.files.single.bytes;
    if (bytes == null || bytes.isEmpty || bytes.length > 256 * 1024 * 1024) {
      setState(() => _error = 'Файл копии отсутствует или слишком большой');
      return;
    }
    final password = await _askBackupPassword();
    if (password == null || !mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map<String, dynamic> ||
          raw['kind'] != 'encrypted_settings_backup') {
        throw const FormatException(
          'Для восстановления ключей требуется зашифрованная копия',
        );
      }
      final decoded = await BackupCrypto.decryptJson(raw, password);
      final keys = decoded['keys'];
      if (keys is! Map<String, dynamic>) {
        throw const FormatException('В копии отсутствуют ключи устройства');
      }
      await LocalIdentityBackup.restore(keys);
      await ref.read(appControllerProvider).loginWithLocalKey();
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Не удалось восстановить ключи или выполнить защищённый вход',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<String?> _askBackupPassword() async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Пароль резервной копии'),
          content: TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Пароль копии'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () {
                final password = controller.text;
                if (password.isNotEmpty) {
                  Navigator.pop(dialogContext, password);
                }
              },
              child: const Text('Восстановить'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
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
      body: AppFormBody(
        maxWidth: 380,
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
              AppNotice(message: homeMovedMessage, tone: AppNoticeTone.warning),
              const SizedBox(height: AppSpacing.md),
            ],
            Text(
              AppConfig.allowPasswordAuthBridge
                  ? 'Телефон, логин или email'
                  : 'Защищённый вход устройства',
              style: text.secondary,
            ),
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
            if (AppConfig.allowPasswordAuthBridge) ...[
              AppTextField(
                controller: _identifierController,
                hintText: 'Телефон / логин / email',
              ),
              const SizedBox(height: AppSpacing.sm),
              AppTextField(
                controller: _passwordController,
                hintText: 'Пароль',
                obscureText: !_passwordVisible,
                trailing: IconButton(
                  tooltip: _passwordVisible
                      ? 'Скрыть пароль'
                      : 'Показать пароль',
                  onPressed: () =>
                      setState(() => _passwordVisible = !_passwordVisible),
                  icon: Icon(
                    _passwordVisible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              AppNotice(message: _error!, tone: AppNoticeTone.danger),
            ],
            const SizedBox(height: AppSpacing.lg),
            if (AppConfig.allowPasswordAuthBridge) ...[
              AppButton(
                label: 'Войти по паролю',
                onPressed: _loading ? null : _submit,
                loading: _loading,
              ),
              const SizedBox(height: AppSpacing.md),
            ],
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
            const SizedBox(height: AppSpacing.md),
            TextButton.icon(
              onPressed: _loading ? null : _restoreEncryptedBackup,
              icon: const Icon(Icons.restore),
              label: const Text('Восстановить ключи из копии'),
            ),
          ],
        ),
      ),
    );
  }
}
