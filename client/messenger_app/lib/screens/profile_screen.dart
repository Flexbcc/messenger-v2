import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_avatar.dart';
import '../core/ui/app_button.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_search_field.dart';
import '../core/ui/app_section.dart';
import '../core/ui/app_tile.dart';
import '../services/api_client.dart';
import '../state/app_controller.dart';
import 'settings_catalog_section_screen.dart';

/// Own profile + identity (name, username, phone, email, password, logout).
/// Search visibility lives under Privacy — not here.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(appControllerProvider).loadMyProfile();
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _editDisplayName() async {
    final controller = ref.read(appControllerProvider);
    final nameController = TextEditingController(text: controller.session?.displayName ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Изменить имя'),
        content: AppTextField(controller: nameController, hintText: 'Имя'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Сохранить')),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    final newName = nameController.text.trim();
    if (newName.isEmpty) return;
    try {
      await controller.updateDisplayName(newName);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Имя обновлено')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    }
  }

  Future<void> _changePassword() async {
    final currentController = TextEditingController();
    final newController = TextEditingController();
    final confirmController = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Сменить пароль'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppTextField(controller: currentController, hintText: 'Текущий пароль', obscureText: true),
            const SizedBox(height: AppSpacing.sm),
            AppTextField(controller: newController, hintText: 'Новый пароль', obscureText: true),
            const SizedBox(height: AppSpacing.sm),
            AppTextField(controller: confirmController, hintText: 'Повторите пароль', obscureText: true),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Сохранить')),
        ],
      ),
    );
    if (saved != true || !mounted) return;

    final current = currentController.text;
    final newPassword = newController.text;
    if (newPassword != confirmController.text) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Пароли не совпадают')));
      return;
    }
    if (newPassword.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Новый пароль — минимум 6 символов')),
      );
      return;
    }

    try {
      await ref.read(appControllerProvider).changePassword(
            currentPassword: current,
            newPassword: newPassword,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Пароль изменён')));
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final controller = ref.watch(appControllerProvider);
    final session = controller.session;

    return Scaffold(
      appBar: AppBar(title: const Text('Профиль')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, style: text.caption, textAlign: TextAlign.center),
                      const SizedBox(height: AppSpacing.md),
                      AppButton(label: 'Повторить', onPressed: _load),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                  children: [
                    const SizedBox(height: AppSpacing.lg),
                    Center(
                      child: AppAvatar(label: session?.displayName, size: AppAvatarSize.large),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Center(
                      child: Text(session?.displayName ?? '', style: text.title),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    AppSettingsGroup(
                      title: 'Данные профиля',
                      children: [
                        AppInfoRow(
                          label: 'Имя',
                          value: session?.displayName ?? '',
                          onTap: _editDisplayName,
                        ),
                        AppInfoRow(
                          label: 'Username (логин)',
                          value: (controller.login?.isNotEmpty ?? false) ? '@${controller.login}' : 'не задан',
                        ),
                        AppInfoRow(label: 'Телефон', value: controller.phone ?? 'не привязан'),
                        AppInfoRow(
                          label: 'Email',
                          value: controller.email ?? 'не привязан',
                          showDivider: false,
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
                      child: Text(
                        'Кто может найти вас по username / телефону — в разделе «Кто меня видит», не здесь.',
                        style: text.caption,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AppSettingsGroup(
                      title: 'Каталог: профиль и вход',
                      children: [
                        AppTile(
                          leading: Icon(Icons.person_outline, color: colors.textSecondary),
                          title: 'Профиль (язык, формат даты)',
                          trailing: AppTile.chevron(context),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const SettingsCatalogSectionScreen(sectionId: 'profile'),
                            ),
                          ),
                        ),
                        AppTile(
                          leading: Icon(Icons.badge_outlined, color: colors.textSecondary),
                          title: 'Телефон, почта, вход и восстановление',
                          subtitle: 'Логин/recovery toggles · синхронизация профиля',
                          trailing: AppTile.chevron(context),
                          showDivider: false,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const SettingsCatalogSectionScreen(sectionId: 'identity'),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
                      child: AppCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('User ID', style: text.caption),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: SelectableText(
                                    session?.userId ?? '',
                                    style: text.body.copyWith(fontSize: 13),
                                  ),
                                ),
                                IconButton(
                                  icon: Icon(Icons.copy_outlined, size: 18, color: colors.textSecondary),
                                  onPressed: () {
                                    Clipboard.setData(ClipboardData(text: session?.userId ?? ''));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Скопировано')),
                                    );
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Text(
                              'Поделитесь ID, чтобы начать защищённый чат.',
                              style: text.caption,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AppSettingsGroup(
                      title: 'Безопасность аккаунта',
                      children: [
                        AppTile(
                          leading: Icon(Icons.lock_outline, color: colors.textSecondary),
                          title: 'Сменить пароль',
                          trailing: AppTile.chevron(context),
                          onTap: _changePassword,
                        ),
                        AppTile(
                          leading: Icon(Icons.visibility_outlined, color: colors.textSecondary),
                          title: 'Кто меня видит и ищет',
                          subtitle: 'Видимость номера, username, онлайн',
                          trailing: AppTile.chevron(context),
                          showDivider: false,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const SettingsCatalogSectionScreen(sectionId: 'privacy'),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
                      child: AppButton(
                        label: 'Выйти',
                        variant: AppButtonVariant.danger,
                        onPressed: () => controller.logout(),
                      ),
                    ),
                  ],
                ),
    );
  }
}
