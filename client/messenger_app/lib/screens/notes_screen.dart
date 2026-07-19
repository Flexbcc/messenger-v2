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
      MaterialPageRoute(builder: (_) => NoteEditorScreen(note: created, isNew: note == null)),
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
                        Icon(Icons.note_alt_outlined, size: 48, color: colors.textMuted),
                        const SizedBox(height: AppSpacing.md),
                        Text('Личное пространство для заметок и ссылок', style: text.caption, textAlign: TextAlign.center),
                        const SizedBox(height: AppSpacing.lg),
                        AppButton(label: 'Создать заметку', onPressed: () => _openNote()),
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
                        margin: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
                        children: [
                          for (var i = 0; i < _notes.length; i++)
                            AppTile(
                              leading: Icon(Icons.sticky_note_2_outlined, color: colors.textSecondary),
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

class _NoteEditorScreenState extends State<NoteEditorScreen> with SingleTickerProviderStateMixin {
  late final TextEditingController _body;
  late final AnimationController _savedPulse;
  bool _saving = false;
  bool _savedFlash = false;

  static const _paper = Color(0xFF1A2433);
  static const _paperEdge = Color(0xFF2A3547);
  static const _inkMuted = Color(0xFF8B9BB0);
  static const _accentWarm = Color(0xFFE8B86D);

  @override
  void initState() {
    super.initState();
    _body = TextEditingController(text: widget.note.body);
    _savedPulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
  }

  @override
  void dispose() {
    _body.dispose();
    _savedPulse.dispose();
    super.dispose();
  }

  Future<void> _flashSaved() async {
    setState(() => _savedFlash = true);
    await _savedPulse.forward(from: 0);
    if (mounted) setState(() => _savedFlash = false);
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
    if (mounted) {
      setState(() => _saving = false);
      await _flashSaved();
      if (widget.isNew) Navigator.pop(context);
    }
  }

  Future<void> _delete() async {
    await NotesStore.instance.delete(widget.note.id);
    if (mounted) Navigator.pop(context);
  }

  String get _titleLine {
    final line = _body.text.trim().split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    if (line.isEmpty) return widget.isNew ? 'Новая заметка' : 'Без названия';
    return line.length > 56 ? '${line.substring(0, 56)}…' : line;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return Scaffold(
      backgroundColor: colors.background,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 132,
            pinned: true,
            stretch: true,
            backgroundColor: colors.surface,
            actions: [
              if (!widget.isNew)
                IconButton(
                  icon: Icon(Icons.delete_outline, color: colors.danger),
                  onPressed: _delete,
                ),
              TextButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? '…' : 'Сохранить'),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              stretchModes: const [StretchMode.zoomBackground],
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      colors.surface,
                      const Color(0xFF152033),
                      _paper,
                    ],
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.screenPadding, 56, AppSpacing.screenPadding, AppSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: _accentWarm.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.sticky_note_2_outlined, color: _accentWarm, size: 22),
                            ),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _titleLine,
                                    style: text.title.copyWith(fontSize: 20),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    formatSyncTime(widget.note.updatedAt),
                                    style: text.caption.copyWith(color: _inkMuted),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedOpacity(
                    opacity: _savedFlash ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: colors.success.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_rounded, size: 14, color: colors.success),
                            const SizedBox(width: 4),
                            Text('Сохранено', style: text.caption.copyWith(color: colors.success)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Container(
                    constraints: BoxConstraints(
                      minHeight: MediaQuery.sizeOf(context).height * 0.55,
                    ),
                    decoration: BoxDecoration(
                      color: _paper,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _paperEdge),
                      boxShadow: [
                        BoxShadow(
                          color: colors.shadow.withValues(alpha: 0.25),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Stack(
                      children: [
                        Positioned(
                          left: 0,
                          top: 16,
                          bottom: 16,
                          child: Container(
                            width: 3,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  _accentWarm.withValues(alpha: 0.7),
                                  _accentWarm.withValues(alpha: 0.05),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 20, 16, 20),
                          child: TextField(
                            controller: _body,
                            maxLines: null,
                            minLines: 18,
                            style: text.body.copyWith(height: 1.55, fontSize: 16),
                            decoration: InputDecoration(
                              hintText: 'Идея, ссылка, список дел…',
                              hintStyle: text.body.copyWith(color: _inkMuted, height: 1.55),
                              border: InputBorder.none,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Только на этом устройстве · не синхронизируется',
                    style: text.caption.copyWith(color: _inkMuted),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
