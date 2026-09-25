/// Local-only hidden conversation stored in the encrypted vault.
class HiddenChat {
  HiddenChat({
    required this.id,
    required this.name,
    this.messages = const [],
    this.disappearingTimer = 'off',
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String name;
  final List<HiddenMessage> messages;
  final String disappearingTimer;
  final DateTime updatedAt;

  HiddenChat copyWith({
    String? name,
    List<HiddenMessage>? messages,
    String? disappearingTimer,
    DateTime? updatedAt,
  }) {
    return HiddenChat(
      id: id,
      name: name ?? this.name,
      messages: messages ?? this.messages,
      disappearingTimer: disappearingTimer ?? this.disappearingTimer,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'messages': messages.map((m) => m.toJson()).toList(),
    'disappearing_timer': disappearingTimer,
    'updated_at': updatedAt.toIso8601String(),
  };

  factory HiddenChat.fromJson(Map<String, dynamic> json) {
    return HiddenChat(
      id: json['id'] as String,
      name: json['name'] as String,
      messages: (json['messages'] as List<dynamic>? ?? [])
          .map((e) => HiddenMessage.fromJson(e as Map<String, dynamic>))
          .toList(),
      disappearingTimer: json['disappearing_timer'] as String? ?? 'off',
      updatedAt:
          DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class HiddenMessage {
  HiddenMessage({
    required this.id,
    required this.text,
    required this.isMine,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String text;
  final bool isMine;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'is_mine': isMine,
    'created_at': createdAt.toIso8601String(),
  };

  factory HiddenMessage.fromJson(Map<String, dynamic> json) {
    return HiddenMessage(
      id: json['id'] as String,
      text: json['text'] as String,
      isMine: json['is_mine'] as bool? ?? false,
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class HiddenVaultData {
  HiddenVaultData({this.chats = const []});

  final List<HiddenChat> chats;

  HiddenVaultData copyWith({List<HiddenChat>? chats}) =>
      HiddenVaultData(chats: chats ?? this.chats);

  Map<String, dynamic> toJson() => {
    'chats': chats.map((c) => c.toJson()).toList(),
  };

  factory HiddenVaultData.fromJson(Map<String, dynamic> json) {
    return HiddenVaultData(
      chats: (json['chats'] as List<dynamic>? ?? [])
          .map((e) => HiddenChat.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
