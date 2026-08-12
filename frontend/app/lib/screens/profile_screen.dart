import 'package:file_picker/file_picker.dart';
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
import 'profile_qr_screen.dart';
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
  bool _editing = false;
  bool _saving = false;
  String? _error;
  final _nameController = TextEditingController();
  final _loginController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _bioController = TextEditingController();

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
      final controller = ref.read(appControllerProvider);
      await controller.loadMyProfile();
      _populateEditors(controller);
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  void _populateEditors(AppController controller) {
    _nameController.text = controller.session?.displayName ?? '';
    _loginController.text = controller.login ?? '';
    _phoneController.text = controller.phone ?? '';
    _emailController.text = controller.email ?? '';
    _bioController.text = controller.bio ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _loginController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      withData: true,
    );
    final file = result?.files.single;
    if (file == null || file.bytes == null || !mounted) return;
    if (file.size > 5 * 1024 * 1024) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Изображение должно быть меньше 5 МБ')),
      );
      return;
    }
    await ref.read(appControllerProvider).setProfileAvatar(file.bytes);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Аватар обновлён')));
    }
  }

  Future<void> _saveProfile() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Укажите имя')));
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(appControllerProvider)
          .updateOwnProfile(
            displayName: name,
            login: _loginController.text.trim(),
            phone: _phoneController.text.trim(),
            email: _emailController.text.trim(),
            bio: _bioController.text.trim(),
          );
      if (mounted) {
        setState(() => _editing = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Профиль сохранён')));
      }
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
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
            AppTextField(
              controller: currentController,
              hintText: 'Текущий пароль',
              obscureText: true,
            ),
            const SizedBox(height: AppSpacing.sm),
            AppTextField(
              controller: newController,
              hintText: 'Новый пароль',
              obscureText: true,
            ),
            const SizedBox(height: AppSpacing.sm),
            AppTextField(
              controller: confirmController,
              hintText: 'Повторите пароль',
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;

    final current = currentController.text;
    final newPassword = newController.text;
    if (newPassword != confirmController.text) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Пароли не совпадают')));
      return;
    }
    if (newPassword.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Новый пароль — минимум 6 символов')),
      );
      return;
    }

    try {
      await ref
          .read(appControllerProvider)
          .changePassword(currentPassword: current, newPassword: newPassword);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Пароль изменён')));
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
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
      appBar: AppBar(
        title: const Text('Профиль'),
        actions: [
          if (!_loading && _error == null)
            TextButton(
              onPressed: _saving
                  ? null
                  : () {
                      if (_editing) {
                        _saveProfile();
                      } else {
                        _populateEditors(controller);
                        setState(() => _editing = true);
                      }
                    },
              child: Text(_editing ? 'Готово' : 'Изменить'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _error!,
                    style: text.caption,
                    textAlign: TextAlign.center,
                  ),
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
                  child: Semantics(
                    button: true,
                    label: 'Изменить аватар',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: _pickAvatar,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          AppAvatar(
                            imageProvider: controller.profileAvatarBytes == null
                                ? null
                                : MemoryImage(controller.profileAvatarBytes!),
                            label: session?.displayName,
                            size: AppAvatarSize.large,
                          ),
                          Positioned(
                            right: -2,
                            bottom: -2,
                            child: CircleAvatar(
                              radius: 17,
                              backgroundColor: colors.primary,
                              child: Icon(
                                Icons.photo_camera_outlined,
                                color: colors.onAccent,
                                size: 18,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Center(
                  child: Text(
                    'Нажмите, чтобы выбрать фото',
                    style: text.caption,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                if (!_editing)
                  Center(
                    child: Text(session?.displayName ?? '', style: text.title),
                  ),
                const SizedBox(height: AppSpacing.xl),
                if (_editing)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.screenPadding,
                    ),
                    child: AppCard(
                      child: Column(
                        children: [
                          TextField(
                            controller: _nameController,
                            decoration: const InputDecoration(labelText: 'Имя'),
                          ),
                          TextField(
                            controller: _loginController,
                            decoration: const InputDecoration(
                              labelText: 'Логин',
                            ),
                          ),
                          TextField(
                            controller: _phoneController,
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(
                              labelText: 'Телефон',
                            ),
                          ),
                          TextField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            decoration: const InputDecoration(
                              labelText: 'Почта',
                            ),
                          ),
                          TextField(
                            controller: _bioController,
                            maxLines: 3,
                            decoration: const InputDecoration(
                              labelText: 'О себе',
                              alignLabelWithHint: true,
                            ),
                          ),
                          if (_saving) ...[
                            const SizedBox(height: AppSpacing.md),
                            const LinearProgressIndicator(),
                          ],
                        ],
                      ),
                    ),
                  )
                else
                  AppSettingsGroup(
                    title: 'Данные профиля',
                    children: [
                      AppInfoRow(
                        label: 'Имя',
                        value: session?.displayName ?? '',
                      ),
                      AppInfoRow(
                        label: 'Логин',
                        value: (controller.login?.isNotEmpty ?? false)
                            ? '@${controller.login}'
                            : 'не задан',
                      ),
                      AppInfoRow(
                        label: 'Телефон',
                        value: controller.phone ?? 'не привязан',
                      ),
                      AppInfoRow(
                        label: 'Почта',
                        value: controller.email ?? 'не привязана',
                      ),
                      AppInfoRow(
                        label: 'О себе',
                        value: controller.bio ?? 'не заполнено',
                        showDivider: false,
                      ),
                    ],
                  ),
                const SizedBox(height: AppSpacing.sm),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.screenPadding,
                  ),
                  child: Text(
                    'Кто может найти вас по username / телефону — в разделе «Кто меня видит», не здесь.',
                    style: text.caption,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                AppSettingsGroup(
                  children: [
                    AppTile(
                      leading: Icon(
                        Icons.qr_code_2,
                        color: colors.textSecondary,
                      ),
                      title: 'Мой QR-код',
                      trailing: AppTile.chevron(context),
                      showDivider: false,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const ProfileQrScreen(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                AppSettingsGroup(
                  title: 'Каталог: профиль и вход',
                  children: [
                    AppTile(
                      leading: Icon(
                        Icons.person_outline,
                        color: colors.textSecondary,
                      ),
                      title: 'Язык и форматы',
                      trailing: AppTile.chevron(context),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SettingsCatalogSectionScreen(
                            sectionId: 'profile',
                            titleOverride: 'Язык и форматы',
                            visibleSettingIds: {
                              'profile.language',
                              'profile.time_format',
                              'profile.date_format',
                            },
                          ),
                        ),
                      ),
                    ),
                    AppTile(
                      leading: Icon(
                        Icons.badge_outlined,
                        color: colors.textSecondary,
                      ),
                      title: 'Телефон и почта',
                      trailing: AppTile.chevron(context),
                      showDivider: false,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SettingsCatalogSectionScreen(
                            sectionId: 'identity',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.screenPadding,
                  ),
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
                              icon: Icon(
                                Icons.copy_outlined,
                                size: 18,
                                color: colors.textSecondary,
                              ),
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(text: session?.userId ?? ''),
                                );
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
                      leading: Icon(
                        Icons.lock_outline,
                        color: colors.textSecondary,
                      ),
                      title: 'Сменить пароль',
                      trailing: AppTile.chevron(context),
                      onTap: _changePassword,
                    ),
                    AppTile(
                      leading: Icon(
                        Icons.visibility_outlined,
                        color: colors.textSecondary,
                      ),
                      title: 'Кто меня видит и ищет',
                      trailing: AppTile.chevron(context),
                      showDivider: false,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SettingsCatalogSectionScreen(
                            sectionId: 'privacy',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xl),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.screenPadding,
                  ),
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
