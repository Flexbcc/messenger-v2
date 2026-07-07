import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_tile.dart';
import '../../services/duress_policy_session.dart';
import '../../state/app_controller.dart';

/// Trusted contacts stored in encrypted duress policy.
class TrustedContactsScreen extends ConsumerStatefulWidget {
  const TrustedContactsScreen({super.key});

  @override
  ConsumerState<TrustedContactsScreen> createState() => _TrustedContactsScreenState();
}

class _TrustedContactsScreenState extends ConsumerState<TrustedContactsScreen> {
  List<String> _ids = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ids = DuressPolicySession.instance.data?.trustedUserIds ?? [];
    if (!mounted) return;
    setState(() {
      _ids = ids;
      _loading = false;
    });
  }

  Future<void> _addById() async {
    final controller = TextEditingController();
    final id = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('User ID доверенного контакта'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'UUID пользователя'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Добавить')),
        ],
      ),
    );
    if (id == null || id.isEmpty) return;
    await DuressPolicySession.instance.addTrusted(id);
    await _load();
  }

  Future<void> _pickFromChats() async {
    final controller = ref.read(appControllerProvider);
    final myId = controller.session?.userId;
    final options = <String, String>{};
    for (final c in controller.conversations) {
      if (c.isGroup) continue;
      for (final id in c.participantUserIds) {
        if (id == myId) continue;
        options[id] = controller.labelFor(id);
      }
    }
    if (!mounted) return;
    if (options.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Нет личных чатов для выбора')));
      return;
    }

    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in options.entries)
              ListTile(
                title: Text(entry.value),
                subtitle: Text(entry.key, style: context.textStyles.micro),
                onTap: () => Navigator.pop(ctx, entry.key),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await DuressPolicySession.instance.addTrusted(picked);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final text = context.textStyles;
    final colors = context.colors;

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!DuressPolicySession.instance.isUnlocked) {
      return Scaffold(
        appBar: AppBar(title: const Text('Доверенные контакты')),
        body: const Center(child: Text('Разблокируйте защищённый раздел')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Доверенные контакты')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: AppCard(
              child: Text(
                'Эти люди получат сигнал в общем чате при срабатывании политики безопасности '
                '(неверный PIN, дополнительный PIN и т.д.).',
                style: text.caption,
              ),
            ),
          ),
          AppSettingsGroup(
            title: 'Добавить',
            children: [
              AppTile(
                leading: Icon(Icons.person_add_outlined, color: colors.textSecondary),
                title: 'Из списка чатов',
                trailing: AppTile.chevron(context),
                onTap: _pickFromChats,
                showDivider: true,
              ),
              AppTile(
                leading: Icon(Icons.badge_outlined, color: colors.textSecondary),
                title: 'По User ID',
                trailing: AppTile.chevron(context),
                onTap: _addById,
              ),
            ],
          ),
          if (_ids.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            AppSettingsGroup(
              title: 'Список',
              children: [
                for (var i = 0; i < _ids.length; i++)
                  AppTile(
                    leading: Icon(Icons.verified_user_outlined, color: colors.textSecondary),
                    title: controller.labelFor(_ids[i]),
                    subtitle: _ids[i],
                    trailing: IconButton(
                      icon: Icon(Icons.remove_circle_outline, color: colors.danger),
                      onPressed: () async {
                        await DuressPolicySession.instance.removeTrusted(_ids[i]);
                        await _load();
                      },
                    ),
                    showDivider: i < _ids.length - 1,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
