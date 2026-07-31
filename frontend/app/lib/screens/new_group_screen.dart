import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_controller.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';
import '../widgets/app_button.dart';
import '../widgets/app_text_field.dart';
import 'chat_screen.dart';

class NewGroupScreen extends ConsumerStatefulWidget {
  const NewGroupScreen({super.key});

  @override
  ConsumerState<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _Member {
  final idController = TextEditingController();
  final nameController = TextEditingController();
}

class _NewGroupScreenState extends ConsumerState<NewGroupScreen> {
  final _groupNameController = TextEditingController();
  final List<_Member> _members = [_Member()];
  bool _loading = false;
  String? _error;

  Future<void> _create() async {
    final groupName = _groupNameController.text.trim();
    final members = _members
        .where((m) => m.idController.text.trim().isNotEmpty)
        .map((m) => MapEntry(m.idController.text.trim(), m.nameController.text.trim()))
        .toList();
    if (groupName.isEmpty || members.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final controller = ref.read(appControllerProvider);
      final conv = await controller.startGroupChat(groupName, members);
      if (mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)));
      }
    } catch (e) {
      setState(() => _error = 'Не удалось создать группу: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(title: const Text('Новая группа')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppTextField(controller: _groupNameController, hintText: 'Название группы'),
            const SizedBox(height: AppSpacing.largeGap),
            Text('Участники (User ID + подпись):', style: AppTypography.secondary),
            const SizedBox(height: AppSpacing.smallGap),
            Expanded(
              child: ListView.separated(
                itemCount: _members.length,
                separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.smallGap),
                itemBuilder: (context, i) => Row(
                  children: [
                    Expanded(
                      child: AppTextField(controller: _members[i].idController, hintText: 'user id'),
                    ),
                    const SizedBox(width: AppSpacing.smallGap),
                    Expanded(
                      child: AppTextField(controller: _members[i].nameController, hintText: 'имя'),
                    ),
                  ],
                ),
              ),
            ),
            TextButton.icon(
              onPressed: () => setState(() => _members.add(_Member())),
              icon: const Icon(Icons.add, color: AppColors.accentBlue),
              label: Text('Добавить участника', style: AppTypography.body.copyWith(color: AppColors.accentBlue)),
            ),
            Container(
              padding: const EdgeInsets.all(AppSpacing.cardPadding),
              decoration: BoxDecoration(
                color: AppColors.surfaceLight,
                borderRadius: BorderRadius.circular(AppRadii.medium),
              ),
              child: Text(
                'Групповые сообщения шифруются end-to-end по sender-key схеме '
                '(см. spec/0301_GROUP_MESSAGING.md).',
                style: AppTypography.caption,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.mediumGap),
              Text(_error!, style: AppTypography.caption.copyWith(color: AppColors.dangerRed)),
            ],
            const SizedBox(height: AppSpacing.mediumGap),
            AppButton(
              label: 'Создать группу',
              onPressed: _loading ? null : _create,
              loading: _loading,
            ),
          ],
        ),
      ),
    );
  }
}
