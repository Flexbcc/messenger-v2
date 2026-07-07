import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_controller.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';
import '../utils/api_errors.dart';
import '../utils/user_id.dart';
import '../widgets/app_button.dart';
import '../widgets/app_text_field.dart';
import 'chat_screen.dart';

/// Start a chat by the other person's User ID (shared out-of-band).
class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key});

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  final _idController = TextEditingController();
  final _nameController = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _start() async {
    final id = normalizeUserId(_idController.text);
    final name = _nameController.text.trim();
    if (id.isEmpty) {
      setState(() => _error = userIdFormatHint());
      return;
    }
    if (!isValidUserIdFormat(id)) {
      setState(() => _error = userIdFormatHint());
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final controller = ref.read(appControllerProvider);
      final conv = await controller.startDirectChat(id, name.isEmpty ? id : name);
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
