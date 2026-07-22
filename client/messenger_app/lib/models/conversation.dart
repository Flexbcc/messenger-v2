class Conversation {
  Conversation({
    required this.id,
    required this.type,
    required this.name,
    required this.participantUserIds,
    this.participantDisplayNames,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String type; // direct | group
  final String? name;
  final List<String> participantUserIds;
  /// Map of userId → display name, populated from server response.
  final Map<String, String>? participantDisplayNames;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory Conversation.fromJson(Map<String, dynamic> json) {
    Map<String, String>? displayNames;
    final raw = json['participant_display_names'];
    if (raw is Map) {
      displayNames = raw.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
    }
    return Conversation(
      id: json['id'] as String,
      type: json['type'] as String,
      name: json['name'] as String?,
      participantUserIds: (json['participant_user_ids'] as List).cast<String>(),
      participantDisplayNames: displayNames,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  bool get isGroup => type == 'group';
}
