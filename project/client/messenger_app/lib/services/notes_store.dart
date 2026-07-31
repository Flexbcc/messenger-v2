import 'package:uuid/uuid.dart';

import '../models/user_note.dart';
import 'local_settings_store.dart';

/// Local-only notes space (encrypted at rest via device prefs).
class NotesStore {
  NotesStore._();
  static final instance = NotesStore._();

  static const _indexKey = 'notes_index_v1';
  final _store = LocalSettingsStore();
  final _uuid = const Uuid();

  Future<List<UserNote>> loadAll() async {
    final ids = await _store.getStringList(_indexKey);
    final notes = <UserNote>[];
    for (final id in ids) {
      final raw = await _store.getString('note_$id', '');
      if (raw.isNotEmpty) notes.add(UserNote.decode(id, raw));
    }
    notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return notes;
  }

  Future<UserNote> create({String body = '', String? title}) async {
    final id = _uuid.v4();
    final note = UserNote(id: id, body: body, title: title, updatedAt: DateTime.now());
    await _persist(note);
    return note;
  }

  Future<void> save(UserNote note) async {
    await _persist(note.copyWith(updatedAt: DateTime.now()));
  }

  Future<void> delete(String id) async {
    final ids = await _store.getStringList(_indexKey);
    ids.remove(id);
    await _store.setStringList(_indexKey, ids);
    await _store.setString('note_$id', '');
  }

  Future<void> _persist(UserNote note) async {
    final ids = await _store.getStringList(_indexKey);
    if (!ids.contains(note.id)) {
      ids.insert(0, note.id);
      await _store.setStringList(_indexKey, ids);
    }
    await _store.setString('note_${note.id}', note.encode());
  }
}

extension on UserNote {
  UserNote copyWith({String? body, String? title, DateTime? updatedAt}) {
    return UserNote(
      id: id,
      body: body ?? this.body,
      title: title ?? this.title,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
