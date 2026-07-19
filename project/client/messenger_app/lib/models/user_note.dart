/// Local personal note — not synced to server.
class UserNote {
  const UserNote({
    required this.id,
    required this.body,
    required this.updatedAt,
    this.title,
  });

  final String id;
  final String body;
  final DateTime updatedAt;
  final String? title;

  String get displayTitle {
    if (title != null && title!.trim().isNotEmpty) return title!.trim();
    final line = body.trim().split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    if (line.isEmpty) return 'Без названия';
    return line.length > 48 ? '${line.substring(0, 48)}…' : line;
  }

  String encode() => '${updatedAt.toIso8601String()}|${title ?? ''}|${body.replaceAll('\n', '\\n')}';

  factory UserNote.decode(String id, String raw) {
    final sep = raw.indexOf('|');
    final sep2 = raw.indexOf('|', sep + 1);
    if (sep < 0 || sep2 < 0) {
      return UserNote(id: id, body: raw, updatedAt: DateTime.now());
    }
    final at = DateTime.tryParse(raw.substring(0, sep)) ?? DateTime.now();
    final title = raw.substring(sep + 1, sep2);
    final body = raw.substring(sep2 + 1).replaceAll('\\n', '\n');
    return UserNote(
      id: id,
      body: body,
      updatedAt: at,
      title: title.isEmpty ? null : title,
    );
  }
}
