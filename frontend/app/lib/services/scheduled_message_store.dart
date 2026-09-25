import '../models/scheduled_message.dart';
import 'local_settings_store.dart';

class ScheduledMessageStore {
  ScheduledMessageStore._();
  static final instance = ScheduledMessageStore._();

  static const _indexKey = 'scheduled_messages_index';
  final _store = LocalSettingsStore();

  Future<List<ScheduledMessage>> loadAll() async {
    final ids = await _store.getStringList(_indexKey);
    final result = <ScheduledMessage>[];
    for (final id in ids) {
      final raw = await _store.getString('scheduled_msg_$id', '');
      if (raw.isNotEmpty) result.add(ScheduledMessage.decode(raw));
    }
    result.sort((a, b) => a.sendAt.compareTo(b.sendAt));
    return result;
  }

  Future<void> save(ScheduledMessage msg) async {
    final ids = await _store.getStringList(_indexKey);
    if (!ids.contains(msg.id)) {
      ids.add(msg.id);
      await _store.setStringList(_indexKey, ids);
    }
    await _store.setString('scheduled_msg_${msg.id}', msg.encode());
  }

  Future<void> remove(String id) async {
    final ids = await _store.getStringList(_indexKey);
    ids.remove(id);
    await _store.setStringList(_indexKey, ids);
    await _store.setString('scheduled_msg_$id', '');
  }
}
