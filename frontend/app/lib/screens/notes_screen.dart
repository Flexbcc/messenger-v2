import 'package:flutter/material.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_button.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_tile.dart';
import '../../models/user_note.dart';
import '../../services/notes_store.dart';
import '../../utils/format.dart';

/// Personal notes — local-only space for text and links.
class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  List<UserNote> _notes = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final notes = await NotesStore.instance.loadAll();
    if (!mounted) return;
    setState(() {
      _notes = notes;
      _loading = false;
    });
  }

  Future<void> _openNote([UserNote? note]) async {
    final created = note ?? await NotesStore.instance.create();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditorScreen(note: created, isNew: note == null),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Заметки'),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: () => _openNote()),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _notes.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.screenPadding),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.note_alt_outlined,
                      size: 48,
                      color: colors.textMuted,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'Личное пространство для заметок и ссылок',
                      style: text.caption,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AppButton(
                      label: 'Создать заметку',
                      onPressed: () => _openNote(),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.screenPadding),
                    child: AppCard(
                      child: Text(
                        'Заметки хранятся только на этом устройстве и не синхронизируются с сервером.',
                        style: text.caption,
                      ),
                    ),
                  ),
                  AppSettingsGroup(
                    margin: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.screenPadding,
                    ),
                    children: [
                      for (var i = 0; i < _notes.length; i++)
                        AppTile(
                          leading: Icon(
                            Icons.sticky_note_2_outlined,
                            color: colors.textSecondary,
                          ),
                          title: _notes[i].displayTitle,
                          subtitle: formatSyncTime(_notes[i].updatedAt),
                          trailing: AppTile.chevron(context),
                          showDivider: i < _notes.length - 1,
                          onTap: () => _openNote(_notes[i]),
                        ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }
}

class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({super.key, required this.note, this.isNew = false});

  final UserNote note;
  final bool isNew;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late final TextEditingController _body;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _body = TextEditingController(text: widget.note.body);
  }

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final note = UserNote(
      id: widget.note.id,
      body: _body.text,
      updatedAt: DateTime.now(),
      title: widget.note.title,
    );
    await NotesStore.instance.save(note);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    await NotesStore.instance.delete(widget.note.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'Новая заметка' : 'Заметка'),
        actions: [
          if (!widget.isNew)
            IconButton(
              icon: Icon(Icons.delete_outline, color: colors.danger),
              onPressed: _delete,
            ),
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Сохранить'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        child: TextField(
          controller: _body,
          maxLines: null,
          expands: true,
          decoration: const InputDecoration(
            hintText: 'Заметка, ссылка, идея…',
            border: InputBorder.none,
          ),
          style: context.textStyles.body,
        ),
      ),
    );
  }
}
