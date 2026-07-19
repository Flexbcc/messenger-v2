import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../models/conversation.dart';
import '../../models/message.dart';
import '../../utils/message_format.dart';
import 'chat_feedback.dart';

/// Shared presets for scheduling and reminders.
class TimeActionPresets {
  static DateTime inSeconds(int s) => DateTime.now().add(Duration(seconds: s));
  static DateTime inMinutes(int m) => DateTime.now().add(Duration(minutes: m));
  static DateTime inHours(int h) => DateTime.now().add(Duration(hours: h));

  static DateTime get thisEvening {
    final now = DateTime.now();
    var target = DateTime(now.year, now.month, now.day, 20, 0);
    if (target.isBefore(now)) target = target.add(const Duration(days: 1));
    return target;
  }

  static DateTime get tomorrowMorning {
    final now = DateTime.now();
    final next = now.add(const Duration(days: 1));
    return DateTime(next.year, next.month, next.day, 9, 0);
  }

  static DateTime get nextMonday {
    final now = DateTime.now();
    var days = (DateTime.monday - now.weekday + 7) % 7;
    if (days == 0) days = 7;
    final monday = now.add(Duration(days: days));
    return DateTime(monday.year, monday.month, monday.day, 9, 0);
  }
}

Future<DateTime?> showSchedulePicker(BuildContext context) {
  final text = context.textStyles;
  return showModalBottomSheet<DateTime>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: Text('Отложить отправку', style: text.title),
          ),
          _pickTile(context, 'Через 10 секунд', TimeActionPresets.inSeconds(10)),
          _pickTile(context, 'Через 1 минуту', TimeActionPresets.inMinutes(1)),
          _pickTile(context, 'Через 10 минут', TimeActionPresets.inMinutes(10)),
          _pickTile(context, 'Сегодня вечером (20:00)', TimeActionPresets.thisEvening),
          _pickTile(context, 'Завтра утром (09:00)', TimeActionPresets.tomorrowMorning),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    ),
  );
}

Future<DateTime?> showReminderPicker(BuildContext context) {
  final text = context.textStyles;
  return showModalBottomSheet<DateTime>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: Text('Напомнить', style: text.title),
          ),
          _pickTile(context, 'Через час', TimeActionPresets.inHours(1)),
          _pickTile(context, 'Завтра утром', TimeActionPresets.tomorrowMorning),
          _pickTile(context, 'В понедельник', TimeActionPresets.nextMonday),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    ),
  );
}

Future<Conversation?> showForwardTargetPicker(
  BuildContext context, {
  required List<Conversation> conversations,
  required String currentConversationId,
  required String Function(Conversation) titleFor,
}) {
  final text = context.textStyles;
  final targets = conversations.where((c) => c.id != currentConversationId).toList();
  return showModalBottomSheet<Conversation>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: Text('Переслать в…', style: text.title),
          ),
          if (targets.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: Text('Нет других чатов', style: text.caption),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final conv in targets)
                    ListTile(
                      leading: const Icon(Icons.chat_bubble_outline),
                      title: Text(titleFor(conv)),
                      onTap: () => Navigator.pop(context, conv),
                    ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    ),
  );
}

Widget _pickTile(BuildContext context, String label, DateTime when) {
  return ListTile(
    title: Text(label),
    subtitle: Text(formatMessageTime(when), style: context.textStyles.caption),
    onTap: () => Navigator.pop(context, when),
  );
}

Future<void> showMessageActionsSheet({
  required BuildContext context,
  required ChatMessage message,
  required bool isMine,
  required bool isPinned,
  required String conversationTitle,
  required VoidCallback onReply,
  required Future<void> Function() onFavorite,
  required Future<void> Function(DateTime when) onReminder,
  required Future<void> Function() onDelete,
  required Future<void> Function() onForward,
  required Future<void> Function() onTogglePin,
  VoidCallback? onEdit,
}) {
  final preview = messagePreview(message);
  final body = messageDisplayBody(message);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.32,
      maxChildSize: 0.88,
      builder: (context, scrollController) => SafeArea(
        child: ListView(
          controller: scrollController,
          children: [
            ListTile(
              title: Text(conversationTitle, style: context.textStyles.caption),
              subtitle: Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            ListTile(
              leading: const Icon(Icons.reply_outlined),
              title: const Text('Ответить'),
              onTap: () {
                Navigator.pop(context);
                onReply();
              },
            ),
            if (body.isNotEmpty && message.contentType == 'text')
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Копировать'),
                onTap: () {
                  Navigator.pop(context);
                  Clipboard.setData(ClipboardData(text: body));
                  ChatFeedback.copied(context);
                },
              ),
            ListTile(
              leading: const Icon(Icons.star_outline),
              title: const Text('В избранное'),
              subtitle: const Text('Появится чат «Избранное» в списке'),
              onTap: () async {
                Navigator.pop(context);
                await onFavorite();
              },
            ),
            ListTile(
              leading: const Icon(Icons.alarm_outlined),
              title: const Text('Напомнить'),
              onTap: () async {
                Navigator.pop(context);
                final when = await showReminderPicker(context);
                if (when != null) await onReminder(when);
              },
            ),
            ListTile(
              leading: const Icon(Icons.forward_outlined),
              title: const Text('Переслать'),
              onTap: () async {
                Navigator.pop(context);
                await onForward();
              },
            ),
            ListTile(
              leading: Icon(isPinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(isPinned ? 'Открепить' : 'Закрепить'),
              onTap: () async {
                Navigator.pop(context);
                await onTogglePin();
              },
            ),
            if (isMine && onEdit != null && message.contentType == 'text')
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Изменить'),
                subtitle: const Text('Текст вернётся в поле ввода'),
                onTap: () {
                  Navigator.pop(context);
                  onEdit();
                },
              ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: context.colors.danger),
              title: Text('Удалить у меня', style: TextStyle(color: context.colors.danger)),
              subtitle: const Text('Скрывает только на этом устройстве'),
              onTap: () async {
                Navigator.pop(context);
                await onDelete();
              },
            ),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    ),
  );
}
