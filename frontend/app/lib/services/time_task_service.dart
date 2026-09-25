import 'package:uuid/uuid.dart';

import '../models/message_reminder.dart';
import '../models/scheduled_message.dart';
import 'message_reminder_store.dart';
import 'scheduled_message_store.dart';

/// Persistence and due-time processing for scheduled sends and reminders.
class TimeTaskService {
  TimeTaskService({Uuid uuid = const Uuid()}) : _uuid = uuid;

  final Uuid _uuid;

  Future<int> scheduleMessage({
    required String conversationId,
    required String text,
    required DateTime sendAt,
    String? replyToMessageId,
    String? replyPreview,
  }) async {
    await ScheduledMessageStore.instance.save(
      ScheduledMessage(
        id: _uuid.v4(),
        conversationId: conversationId,
        text: text.trim(),
        sendAt: sendAt,
        createdAt: DateTime.now(),
        replyToMessageId: replyToMessageId,
        replyPreview: replyPreview,
      ),
    );
    return scheduledCount();
  }

  Future<int> cancelScheduledMessage(String id) async {
    await ScheduledMessageStore.instance.remove(id);
    return scheduledCount();
  }

  Future<void> addReminder({
    required String conversationId,
    required String messageId,
    required String preview,
    required DateTime remindAt,
  }) {
    return MessageReminderStore.instance.save(
      MessageReminder(
        id: _uuid.v4(),
        conversationId: conversationId,
        messageId: messageId,
        preview: preview,
        remindAt: remindAt,
      ),
    );
  }

  Future<int> processScheduled(
    Future<bool> Function(ScheduledMessage task) deliver,
  ) async {
    final now = DateTime.now();
    final due = (await ScheduledMessageStore.instance.loadAll())
        .where((task) => !task.sendAt.isAfter(now))
        .toList();
    for (final task in due) {
      if (await deliver(task)) {
        await ScheduledMessageStore.instance.remove(task.id);
      }
    }
    return scheduledCount();
  }

  Future<void> processReminders(
    Future<void> Function(MessageReminder reminder) apply,
  ) async {
    final now = DateTime.now();
    final due = (await MessageReminderStore.instance.loadAll())
        .where((reminder) => !reminder.remindAt.isAfter(now))
        .toList();
    for (final reminder in due) {
      await apply(reminder);
      await MessageReminderStore.instance.remove(reminder.id);
    }
  }

  Future<int> scheduledCount() async =>
      (await ScheduledMessageStore.instance.loadAll()).length;
}
