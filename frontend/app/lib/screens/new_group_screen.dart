import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_button.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_form_body.dart';
import '../core/ui/app_notice.dart';
import '../core/ui/app_page.dart';
import '../core/ui/app_search_field.dart';
import '../state/app_controller.dart';
import 'chat_screen.dart';

class NewGroupScreen extends ConsumerStatefulWidget {
  const NewGroupScreen({super.key});

  @override
  ConsumerState<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _Member {
  final idController = TextEditingController();
  final nameController = TextEditingController();

  void dispose() {
    idController.dispose();
    nameController.dispose();
  }
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
        .map(
          (m) => MapEntry(
            m.idController.text.trim(),
            m.nameController.text.trim(),
          ),
        )
        .toList();
    if (groupName.isEmpty || members.isEmpty) {
      setState(
        () => _error = groupName.isEmpty
            ? 'Укажите название группы'
            : 'Добавьте хотя бы одного участника',
      );
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final controller = ref.read(appControllerProvider);
      final conv = await controller.startGroupChat(groupName, members);
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)),
        );
      }
    } catch (_) {
      setState(
        () => _error =
            'Не удалось создать группу. Проверьте участников и подключение.',
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _removeMember(int index) {
    if (_members.length == 1) {
      _members.first.idController.clear();
      _members.first.nameController.clear();
      return;
    }
    final removed = _members.removeAt(index);
    removed.dispose();
    setState(() {});
  }

  @override
  void dispose() {
    _groupNameController.dispose();
    for (final member in _members) {
      member.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    return AppPage(
      title: 'Новая группа',
      scroll: false,
      child: AppFormBody(
        maxWidth: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppTextField(
              controller: _groupNameController,
              hintText: 'Название группы',
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Участники',
              style: text.subtitle.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Укажите User ID. Имя используется только как локальная подпись.',
              style: text.caption,
            ),
            const SizedBox(height: AppSpacing.md),
            for (var i = 0; i < _members.length; i++) ...[
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Участник ${i + 1}',
                            style: text.subtitle,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Удалить участника',
                          onPressed: _loading ? null : () => _removeMember(i),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    AppTextField(
                      controller: _members[i].idController,
                      hintText: 'User ID',
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    AppTextField(
                      controller: _members[i].nameController,
                      hintText: 'Имя у вас (необязательно)',
                    ),
                  ],
                ),
              ),
              if (i < _members.length - 1)
                const SizedBox(height: AppSpacing.sm),
            ],
            const SizedBox(height: AppSpacing.sm),
            TextButton.icon(
              onPressed: _loading
                  ? null
                  : () => setState(() => _members.add(_Member())),
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: const Text('Добавить участника'),
            ),
            const SizedBox(height: AppSpacing.md),
            AppCard(
              color: colors.primary.withValues(alpha: 0.08),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lock_outline, size: 20, color: colors.primary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'Сообщения группы шифруются на устройствах участников. Ноды передают только зашифрованные данные.',
                      style: text.caption,
                    ),
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              AppNotice(message: _error!, tone: AppNoticeTone.danger),
            ],
            const SizedBox(height: AppSpacing.lg),
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
