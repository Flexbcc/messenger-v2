import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_tile.dart';
import '../../security/secret_chat_security.dart';
import '../../services/secret_chat_preferences_store.dart';
import '../../state/app_controller.dart';

/// Password, idle timeout, and disappearing messages for secret chat sessions.
class SecretChatSettingsScreen extends ConsumerStatefulWidget {
  const SecretChatSettingsScreen({super.key});

  @override
  ConsumerState<SecretChatSettingsScreen> createState() => _SecretChatSettingsScreenState();
}

class _SecretChatSettingsScreenState extends ConsumerState<SecretChatSettingsScreen> {
  bool _loading = true;
  bool _configured = false;
  int _timeoutMin = 3;
  int? _disappearSec;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = SecretChatPreferencesStore.instance;
    final configured = await SecretChatSecurity.isConfigured();
    final timeout = await store.sessionTimeoutMinutes();
    final disappear = await store.secretDisappearingSeconds();
    if (!mounted) return;
    setState(() {
      _configured = configured;
      _timeoutMin = timeout;
      _disappearSec = disappear;
      _loading = false;
    });
  }

  Future<void> _setPassword() async {
    final controller = TextEditingController();
    final confirm = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_configured ? 'Сменить пароль' : 'Задать пароль'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'В чате введите пароль и два пробела в конце, затем Enter — сообщение не отправится.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Пароль секретной комнаты'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: confirm,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Повторите пароль'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
        ],
      ),
    );
    if (saved != true || !mounted) return;

    final password = controller.text;
    if (password != confirm.text) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Пароли не совпадают')));
      return;
    }
    final warnings = SecretChatSecurity.validateForSetup(password);
    if (warnings.isNotEmpty) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Слабый пароль'),
          content: Text('Рекомендации:\n• ${warnings.join('\n• ')}\n\nВсё равно сохранить?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Изменить')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
          ],
        ),
      );
      if (proceed != true) return;
    }
    await SecretChatSecurity.savePassword(password);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Пароль сохранён')));
    setState(() => _configured = true);
  }

  Future<void> _clearPassword() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить пароль?'),
        content: const Text('Секретный режим в чатах станет недоступен.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    await SecretChatSecurity.clearPassword();
    if (!mounted) return;
    setState(() => _configured = false);
  }

  Future<void> _pickTimeout() async {
    final next = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in const [1, 2, 3, 5])
              ListTile(
                title: Text('$m мин'),
                trailing: _timeoutMin == m ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, m),
              ),
          ],
        ),
      ),
    );
    if (next == null) return;
    await SecretChatPreferencesStore.instance.setSessionTimeoutMinutes(next);
    setState(() => _timeoutMin = next);
  }

  Future<void> _pickDisappearing() async {
    const offSentinel = -1;
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (label, sec) in SecretChatPreferencesStore.disappearingOptions)
              ListTile(
                title: Text(label),
                trailing: _disappearSec == sec ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, sec ?? offSentinel),
              ),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) return;
    final selected = picked == offSentinel ? null : picked;
    if (selected == _disappearSec) return;
    await SecretChatPreferencesStore.instance.setSecretDisappearingSeconds(selected);
    await ref.read(appControllerProvider).loadSecretChatPreferences();
    setState(() => _disappearSec = selected);
  }

  String _disappearLabel() {
    for (final (label, sec) in SecretChatPreferencesStore.disappearingOptions) {
      if (sec == _disappearSec) return label;
    }
    return 'Выкл';
  }

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Секретная комната')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: Text(
              'Временный режим внутри обычного чата. Сообщения помечаются локально и скрыты без пароля. '
              'Выход в список чатов всегда выключает режим.',
              style: text.caption,
            ),
          ),
          AppSettingsGroup(
            title: 'Пароль',
            children: [
              AppTile(
                leading: Icon(Icons.lock_outline, color: context.colors.textSecondary),
                title: _configured ? 'Сменить пароль' : 'Задать пароль',
                subtitle: _configured ? 'В чате: пароль + два пробела + Enter' : 'Обязательно перед использованием',
                trailing: AppTile.chevron(context),
                onTap: _setPassword,
                showDivider: _configured,
              ),
              if (_configured)
                AppTile(
                  leading: Icon(Icons.lock_open_outlined, color: context.colors.textSecondary),
                  title: 'Удалить пароль',
                  trailing: AppTile.chevron(context),
                  onTap: _clearPassword,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Сессия в чате',
            children: [
              AppTile(
                leading: Icon(Icons.timer_outlined, color: context.colors.textSecondary),
                title: 'Таймер бездействия',
                subtitle: '$_timeoutMin мин — только пока вы в чате',
                trailing: AppTile.chevron(context),
                onTap: _pickTimeout,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Секретные сообщения',
            children: [
              AppTile(
                leading: Icon(Icons.auto_delete_outlined, color: context.colors.textSecondary),
                title: 'Исчезающие секретные',
                subtitle: _disappearLabel(),
                trailing: AppTile.chevron(context),
                onTap: _pickDisappearing,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
