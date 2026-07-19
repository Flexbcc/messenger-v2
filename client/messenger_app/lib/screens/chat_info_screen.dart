import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_avatar.dart';
import '../core/ui/app_badge.dart';
import '../core/ui/app_bottom_sheet.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_switch_tile.dart';
import '../core/ui/app_tile.dart';
import '../models/conversation.dart';
import '../state/app_controller.dart';
import '../widgets/chat/pinned_messages_sheet.dart';
import 'chat_media_screen.dart';
import 'chat_search_screen.dart';
import 'chat_screen.dart';

class ChatInfoScreen extends ConsumerStatefulWidget {
  const ChatInfoScreen({super.key, required this.conversation});
  final Conversation conversation;

  @override
  ConsumerState<ChatInfoScreen> createState() => _ChatInfoScreenState();
}

class _ChatInfoScreenState extends ConsumerState<ChatInfoScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(appControllerProvider).loadChatPreferences(widget.conversation.id));
  }

  Future<void> _confirmClearHistory() async {
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Очистить историю чата?'),
        content: const Text(
          'Сообщения будут удалены только на этом устройстве. '
          'На сервере и у собеседника они останутся.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Очистить', style: TextStyle(color: colors.danger)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(appControllerProvider).clearLocalHistory(widget.conversation.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('История очищена на этом устройстве')));
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _pickDisappearing() async {
    const options = [(null, 'Выключено'), (86400, '24 часа'), (604800, '7 дней'), (2592000, '30 дней')];
    final controller = ref.read(appControllerProvider);
    final current = controller.disappearingSeconds[widget.conversation.id];
    final colors = context.colors;
    final text = context.textStyles;

    final selected = await showAppBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: Column(
                children: [
                  Text('Исчезающие сообщения', style: text.title),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Только на этом устройстве — старые сообщения скрываются локально.',
                    style: text.caption,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            for (final (seconds, label) in options)
              ListTile(
                title: Text(label, style: text.body),
                trailing: current == seconds ? Icon(Icons.check, color: colors.primary) : null,
                onTap: () => Navigator.of(context).pop(seconds ?? 0),
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await controller.setDisappearingSeconds(widget.conversation.id, selected == 0 ? null : selected);
  }

  Future<void> _confirmHideAsSecret() async {
    final colors = context.colors;
    final controller = ref.read(appControllerProvider);
    final title = controller.conversationTitle(widget.conversation);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Скрыть чат?'),
        content: Text(
          '«$title» исчезнет из основного списка. Доступ — через Private Mode → Скрытые чаты или PIN.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Скрыть', style: TextStyle(color: colors.warning)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await controller.hideConversationAsSecret(widget.conversation.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Чат скрыт')));
        Navigator.of(context).pop();
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final controller = ref.watch(appControllerProvider);
    final title = controller.conversationTitle(widget.conversation);
    final isGroup = widget.conversation.isGroup;
    final isMuted = controller.chatMuted[widget.conversation.id] ?? false;
    final isSecret = controller.isSecretHidden(widget.conversation.id);
    final imageCount = controller.imageMessagesFor(widget.conversation.id).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Информация о чате')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          const SizedBox(height: AppSpacing.xl),
          Center(
            child: Column(
              children: [
                AppAvatar(label: title, isGroup: isGroup, size: AppAvatarSize.large),
                const SizedBox(height: AppSpacing.md),
                Text(title, style: text.title),
                if (isGroup) ...[
                  const SizedBox(height: 2),
                  Text('${widget.conversation.participantUserIds.length} участников', style: text.caption),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          AppSettingsGroup(
            children: [
              AppTile(
                leading: Icon(Icons.search, color: colors.textSecondary),
                title: 'Поиск в чате',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ChatSearchScreen(conversation: widget.conversation)),
                ),
              ),
              AppTile(
                leading: Icon(Icons.push_pin_outlined, color: colors.textSecondary),
                title: 'Закреплённые',
                trailingText: controller.pinnedCountFor(widget.conversation.id) > 0
                    ? '${controller.pinnedCountFor(widget.conversation.id)}'
                    : null,
                trailing: AppTile.chevron(context),
                onTap: () => showPinnedMessagesSheet(
                  context: context,
                  conversation: widget.conversation,
                  onOpenMessage: (messageId) {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ChatScreen(
                          conversation: widget.conversation,
                          scrollToMessageId: messageId,
                        ),
                      ),
                    );
                  },
                ),
              ),
              AppSwitchTile(
                leading: Icon(Icons.notifications_outlined, color: colors.textSecondary),
                title: 'Уведомления',
                subtitle: 'Для этого чата на этом устройстве',
                value: !isMuted,
                onChanged: (v) => controller.setChatMuted(widget.conversation.id, !v),
              ),
              AppTile(
                leading: Icon(Icons.perm_media_outlined, color: colors.textSecondary),
                title: 'Медиа, файлы и ссылки',
                trailingText: imageCount > 0 ? '$imageCount фото' : null,
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ChatMediaScreen(conversation: widget.conversation)),
                ),
              ),
              AppTile(
                leading: Icon(Icons.lock_outline, color: colors.primary),
                title: 'Шифрование',
                trailing: AppSecurityBadge(icon: Icons.verified, label: 'E2E', color: colors.success),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Шифрование'),
                    content: Text(
                      isGroup
                          ? 'Сквозное шифрование включено. Группа защищена sender-key схемой Signal.'
                          : 'Сквозное шифрование Signal — сообщения доступны только участникам чата.',
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Понятно')),
                    ],
                  ),
                ),
              ),
              AppTile(
                leading: Icon(Icons.timer_outlined, color: colors.textSecondary),
                title: 'Исчезающие сообщения',
                trailingText: controller.disappearingLabel(widget.conversation.id),
                trailing: AppTile.chevron(context),
                showDivider: false,
                onTap: _pickDisappearing,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            children: [
              if (!isSecret)
                AppTile(
                  leading: Icon(Icons.visibility_off_outlined, color: colors.warning),
                  title: 'Скрыть чат',
                  subtitle: 'Убрать из основного списка',
                  onTap: _confirmHideAsSecret,
                  showDivider: true,
                ),
              AppTile(
                leading: Icon(Icons.delete_outline, color: colors.danger),
                title: 'Очистить историю чата',
                danger: true,
                showDivider: false,
                onTap: _confirmClearHistory,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
