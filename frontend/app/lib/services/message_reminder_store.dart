import '../models/message_reminder.dart';
import 'local_settings_store.dart';

class MessageReminderStore {
  MessageReminderStore._();
  static final instance = MessageReminderStore._();

  static const _indexKey = 'message_reminders_index';
  final _store = LocalSettingsStore();

  Future<List<MessageReminder>> loadAll() async {
    final ids = await _store.getStringList(_indexKey);
    final result = <MessageReminder>[];
    for (final id in ids) {
      final raw = await _store.getString('reminder_$id', '');
      if (raw.isNotEmpty) result.add(MessageReminder.decode(raw));
    }
    result.sort((a, b) => a.remindAt.compareTo(b.remindAt));
    return result;
  }

  Future<void> save(MessageReminder reminder) async {
    final ids = await _store.getStringList(_indexKey);
    if (!ids.contains(reminder.id)) {
      ids.add(reminder.id);
      await _store.setStringList(_indexKey, ids);
    }
    await _store.setString('reminder_${reminder.id}', reminder.encode());
  }

  Future<void> remove(String id) async {
    final ids = await _store.getStringList(_indexKey);
    ids.remove(id);
    await _store.setStringList(_indexKey, ids);
    await _store.setString('reminder_$id', '');
  }
}
