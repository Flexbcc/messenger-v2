import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_client.dart';
import '../services/settings_runtime.dart';
import '../state/app_controller.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';
import '../utils/api_errors.dart';
import '../utils/user_id.dart';
import '../widgets/app_button.dart';
import '../widgets/app_text_field.dart';
import 'chat_screen.dart';

enum _SearchMode { userId, username, phone }

/// Start a chat by User ID, username, or phone (gated by privacy settings).
class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key});

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  final _idController = TextEditingController();
  final _nameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _loading = false;
  String? _error;
  _SearchMode _mode = _SearchMode.userId;

  Future<void> _start() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final controller = ref.read(appControllerProvider);
      String id;
      String label;
      switch (_mode) {
        case _SearchMode.username:
          if (!await SettingsRuntime.instance.usernameSearchAllowed()) {
            setState(() => _error = 'Поиск по username отключён в настройках приватности');
            return;
          }
          final login = _usernameController.text.trim();
          if (login.length < 3) {
            setState(() => _error = 'Username минимум 3 символа');
            return;
          }
          final api = ApiClient(accessToken: controller.session?.accessToken);
          final found = await api.searchUserByLogin(login);
          id = found['user_id'] as String;
          label = found['display_name'] as String? ?? login;
        case _SearchMode.phone:
          if (!await SettingsRuntime.instance.phoneSearchAllowed()) {
            setState(() => _error = 'Поиск по телефону отключён (privacy.phone_search)');
            return;
          }
          final phone = _phoneController.text.trim();
          if (phone.length < 5) {
            setState(() => _error = 'Введите номер телефона');
            return;
          }
          // No dedicated phone directory API yet — treat as local peer id lookup fail-soft.
          setState(() => _error = 'Поиск по телефону разрешён настройками, но API каталога ещё нет');
          return;
        case _SearchMode.userId:
          id = normalizeUserId(_idController.text);
          label = _nameController.text.trim();
          if (id.isEmpty) {
            setState(() => _error = userIdFormatHint());
            return;
          }
          if (!isValidUserIdFormat(id)) {
            setState(() => _error = userIdFormatHint());
            return;
          }
      }
      final conv = await controller.startDirectChat(id, label.isEmpty ? id : label);
      if (mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)));
      }
    } catch (e) {
      setState(() => _error = friendlyApiError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _idController.dispose();
    _nameController.dispose();
    _usernameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final myId = ref.watch(appControllerProvider).session?.userId;

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(title: const Text('Новый чат')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (myId != null) ...[
              Container(
                padding: const EdgeInsets.all(AppSpacing.cardPadding),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(AppRadii.medium),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Ваш User ID (отправьте собеседнику):', style: AppTypography.caption),
                    const SizedBox(height: AppSpacing.smallGap / 2),
                    Row(
                      children: [
                        Expanded(child: SelectableText(myId, style: AppTypography.body)),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 18),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: myId));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Ваш User ID скопирован')),
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.largeGap),
            ],
            SegmentedButton<_SearchMode>(
              segments: const [
                ButtonSegment(value: _SearchMode.userId, label: Text('ID'), icon: Icon(Icons.badge_outlined)),
                ButtonSegment(value: _SearchMode.username, label: Text('User'), icon: Icon(Icons.alternate_email)),
                ButtonSegment(value: _SearchMode.phone, label: Text('Тел.'), icon: Icon(Icons.phone_outlined)),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: AppSpacing.largeGap),
            if (_mode == _SearchMode.username) ...[
              Text('Username собеседника:', style: AppTypography.secondary),
              const SizedBox(height: AppSpacing.smallGap),
              AppTextField(controller: _usernameController, hintText: 'kekwekke_user'),
            ] else if (_mode == _SearchMode.phone) ...[
              Text('Телефон собеседника:', style: AppTypography.secondary),
              const SizedBox(height: AppSpacing.smallGap),
              AppTextField(controller: _phoneController, hintText: '+79001234567'),
            ] else ...[
              Text(
                'User ID собеседника (UUID из Настройки → Аккаунт):',
                style: AppTypography.secondary,
              ),
              const SizedBox(height: AppSpacing.smallGap),
              AppTextField(
                controller: _idController,
                hintText: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
              ),
              const SizedBox(height: AppSpacing.largeGap),
              Text('Как подписать чат у себя (необязательно):', style: AppTypography.secondary),
              const SizedBox(height: AppSpacing.smallGap),
              AppTextField(controller: _nameController, hintText: 'Имя'),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.mediumGap),
              Text(_error!, style: AppTypography.caption.copyWith(color: AppColors.dangerRed)),
            ],
            const SizedBox(height: AppSpacing.sectionGap),
            AppButton(
              label: 'Начать чат',
              onPressed: _loading ? null : _start,
              loading: _loading,
            ),
          ],
        ),
      ),
    );
  }
}
