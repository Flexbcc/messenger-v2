import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_switch_tile.dart';
import '../../core/ui/app_tile.dart';
import '../../models/duress_policy.dart';
import '../../security/secret_chat_security.dart';
import '../../services/privacy_preferences_store.dart';
import '../../services/privacy_setup_summary.dart';
import '../../services/secret_chat_preferences_store.dart';
import '../../state/app_controller.dart';
import '../../widgets/private/duress_behavior_card.dart';
import 'private_settings_access.dart';

/// Secret room — password, session, disappearing + fail behaviour (inline).
class PrivacySecretSectionScreen extends ConsumerStatefulWidget {
  const PrivacySecretSectionScreen({super.key});

  @override
  ConsumerState<PrivacySecretSectionScreen> createState() => _PrivacySecretSectionScreenState();
}

class _PrivacySecretSectionScreenState extends ConsumerState<PrivacySecretSectionScreen> {
  PrivacySetupSummary? _summary;
  bool _roomEnabled = true;
  bool _configured = false;
  int _timeoutMin = 3;
  int? _disappearSec;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Future.microtask(_reload);
  }

  @override
  void dispose() {
    PrivateSettingsAccess.lockVault();
    super.dispose();
  }

  Future<void> _reload() async {
    await warmDuressMirror();
    final s = await PrivacySetupSummary.load();
    final prefs = PrivacyPreferencesStore();
    final store = SecretChatPreferencesStore.instance;
    final configured = await SecretChatSecurity.isConfigured();
    final enabled = await prefs.secretRoomEnabled();
    final timeout = await store.sessionTimeoutMinutes();
    final disappear = await store.secretDisappearingSeconds();
    if (!mounted) return;
    setState(() {
      _summary = s;
      _configured = configured;
      _roomEnabled = enabled;
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
              'В чате: пароль + два пробела в конце, затем Enter — сообщение не отправится.',
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
    if (controller.text != confirm.text) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Пароли не совпадают')));
      return;
    }
    await SecretChatSecurity.savePassword(controller.text);
    await _reload();
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
    const off = -1;
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
                onTap: () => Navigator.pop(ctx, sec ?? off),
              ),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) return;
    final selected = picked == off ? null : picked;
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
    final colors = context.colors;
    final text = context.textStyles;
    final p = _summary;

    if (_loading || p == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!p.canConfigureSecretRoom) {
      return Scaffold(
        appBar: AppBar(title: const Text('Секретная комната')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: Text(
              'Сначала настройте основной и дополнительный PIN',
              style: text.body,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Секретная комната')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: AppCard(
              child: Text(
                'Временный режим внутри обычного чата. Сообщения скрыты без пароля. '
                'Выход в список чатов выключает режим.',
                style: text.caption,
              ),
            ),
          ),
          AppSettingsGroup(
            title: 'Пароль в чате',
            children: [
              AppTile(
                leading: Icon(Icons.lock_outline, color: colors.textSecondary),
                title: _configured ? 'Сменить пароль' : 'Задать пароль',
                subtitle: _configured ? 'Ввод: пароль + два пробела + Enter' : 'Обязательно',
                trailing: AppTile.chevron(context),
                onTap: _setPassword,
              ),
              if (_configured)
                AppSwitchTile(
                  leading: Icon(Icons.lock_open_outlined, color: colors.textSecondary),
                  title: 'Секретная комната включена',
                  value: _roomEnabled,
                  onChanged: (v) async {
                    await PrivacyPreferencesStore().setSecretRoomEnabled(v);
                    setState(() => _roomEnabled = v);
                  },
                  showDivider: false,
                ),
            ],
          ),
          if (_configured) ...[
            const SizedBox(height: AppSpacing.lg),
            AppSettingsGroup(
              title: 'Сессия',
              children: [
                AppTile(
                  leading: Icon(Icons.timer_outlined, color: colors.textSecondary),
                  title: 'Таймер бездействия',
                  subtitle: '$_timeoutMin мин — пока вы в чате',
                  trailing: AppTile.chevron(context),
                  onTap: _pickTimeout,
                  showDivider: false,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            AppSettingsGroup(
              title: 'Секретные сообщения',
              children: [
                AppTile(
                  leading: Icon(Icons.auto_delete_outlined, color: colors.textSecondary),
                  title: 'Исчезающие секретные',
                  subtitle: _disappearLabel(),
                  trailing: AppTile.chevron(context),
                  onTap: _pickDisappearing,
                  showDivider: false,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
              child: Text('Неверный пароль комнаты', style: text.sectionTitle),
            ),
            const SizedBox(height: AppSpacing.sm),
            const DuressBehaviorCard(
              title: 'Правила (ошибка пароля)',
              trigger: DuressTrigger.secretRoomActivateFail,
            ),
            const SizedBox(height: AppSpacing.md),
            AppSettingsGroup(
              title: 'Изменить',
              children: [
                AppTile(
                  leading: Icon(Icons.tune_outlined, color: colors.textSecondary),
                  title: 'Правила duress',
                  subtitle: 'Пороги для неверного пароля комнаты',
                  trailing: AppTile.chevron(context),
                  onTap: () async {
                    await PrivateSettingsAccess.openDuressRules(context, keepUnlocked: true);
                    await _reload();
                  },
                  showDivider: false,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
