import 'model_parsing.dart';

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

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final type = requiredBoundedString(json, 'type', maxLength: 20);
    if (type != 'direct' && type != 'group') {
      throw const FormatException('invalid conversation type');
    }
    return Conversation(
      id: requiredBoundedString(json, 'id', maxLength: 128),
      type: type,
      name: optionalBoundedString(json, 'name', maxLength: 100),
      participantUserIds: requiredBoundedStringList(
        json,
        'participant_user_ids',
        maxItems: 512,
        maxItemLength: 128,
      ),
      createdAt: requiredDateTime(json, 'created_at'),
      updatedAt: requiredDateTime(json, 'updated_at'),
    );
  }

  bool get isGroup => type == 'group';
}
