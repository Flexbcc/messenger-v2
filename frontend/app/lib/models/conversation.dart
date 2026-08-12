class Conversation {
  Conversation({
    required this.id,
    required this.type,
    required this.name,
    required this.participantUserIds,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String type; // direct | group
  final String? name;
  final List<String> participantUserIds;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'] as String,
    type: json['type'] as String,
    name: json['name'] as String?,
    participantUserIds: (json['participant_user_ids'] as List).cast<String>(),
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
  );

  bool get isGroup => type == 'group';
}
