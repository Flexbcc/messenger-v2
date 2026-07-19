/// Trigger types — spec/0404_DURESS_POLICY.md
enum DuressTrigger {
  pinUnlockOkReal,
  pinUnlockOkDecoy,
  pinUnlockFail,
  decoyPinStreak,
  secretRoomActivateOk,
  secretRoomActivateFail,
  appLockFail,
  panicExit,
  emergencyLock,
}

extension DuressTriggerJson on DuressTrigger {
  String get wire => switch (this) {
        DuressTrigger.pinUnlockOkReal => 'pin_unlock_ok_real',
        DuressTrigger.pinUnlockOkDecoy => 'pin_unlock_ok_decoy',
        DuressTrigger.pinUnlockFail => 'pin_unlock_fail',
        DuressTrigger.decoyPinStreak => 'decoy_pin_streak',
        DuressTrigger.secretRoomActivateOk => 'secret_room_activate_ok',
        DuressTrigger.secretRoomActivateFail => 'secret_room_activate_fail',
        DuressTrigger.appLockFail => 'app_lock_fail',
        DuressTrigger.panicExit => 'panic_exit',
        DuressTrigger.emergencyLock => 'emergency_lock',
      };

  static DuressTrigger? parse(String? raw) {
    if (raw == null) return null;
    for (final t in DuressTrigger.values) {
      if (t.wire == raw) return t;
    }
    return null;
  }

  String get labelRu => switch (this) {
        DuressTrigger.pinUnlockOkReal => 'Успешный основной PIN',
        DuressTrigger.pinUnlockOkDecoy => 'Успешный дополнительный PIN',
        DuressTrigger.pinUnlockFail => 'Неверный PIN',
        DuressTrigger.decoyPinStreak => 'Дополнительный PIN',
        DuressTrigger.secretRoomActivateOk => 'Секретная комната открыта',
        DuressTrigger.secretRoomActivateFail => 'Неверный пароль секретной комнаты',
        DuressTrigger.appLockFail => 'Неверный PIN блокировки приложения',
        DuressTrigger.panicExit => 'Быстрый выход',
        DuressTrigger.emergencyLock => 'Экстренная блокировка',
      };

  /// Triggers users can assign in custom recipes.
  static const editable = [
    DuressTrigger.pinUnlockFail,
    DuressTrigger.decoyPinStreak,
    DuressTrigger.secretRoomActivateFail,
    DuressTrigger.appLockFail,
    DuressTrigger.panicExit,
    DuressTrigger.emergencyLock,
  ];
}

enum DuressActionType {
  none,
  lockPinUi,
  lockApp,
  notifyTrustedChat,
  relayEvent,
  purgeSecretMessages,
  wipePrivateVault,
  deactivateSecretSessions,
  showDecoyOnly,
  deleteChats,
}

extension DuressActionTypeJson on DuressActionType {
  String get wire => switch (this) {
        DuressActionType.none => 'none',
        DuressActionType.lockPinUi => 'lock_pin_ui',
        DuressActionType.lockApp => 'lock_app',
        DuressActionType.notifyTrustedChat => 'notify_trusted_chat',
        DuressActionType.relayEvent => 'relay_event',
        DuressActionType.purgeSecretMessages => 'purge_secret_messages',
        DuressActionType.wipePrivateVault => 'wipe_private_vault',
        DuressActionType.deactivateSecretSessions => 'deactivate_secret_sessions',
        DuressActionType.showDecoyOnly => 'show_decoy_only',
        DuressActionType.deleteChats => 'delete_chats',
      };

  String get labelRu => switch (this) {
        DuressActionType.none => 'Ничего',
        DuressActionType.lockPinUi => 'Блокировка ввода PIN',
        DuressActionType.lockApp => 'Блокировка приложения',
        DuressActionType.notifyTrustedChat => 'Оповестить доверенных',
        DuressActionType.relayEvent => 'Сигнал через сервер',
        DuressActionType.purgeSecretMessages => 'Удалить secret-сообщения',
        DuressActionType.wipePrivateVault => 'Очистить Private Mode',
        DuressActionType.deactivateSecretSessions => 'Сброс secret-сессий',
        DuressActionType.showDecoyOnly => 'Показать decoy-интерфейс',
        DuressActionType.deleteChats => 'Очистить / убрать чаты',
      };

  String get catalogHintRu => switch (this) {
        DuressActionType.notifyTrustedChat => 'Сообщение доверенным при срабатывании условия',
        DuressActionType.relayEvent => 'Числовой код на сервер (без текста)',
        DuressActionType.deleteChats => 'Локально очистить историю или убрать чат из списка',
        DuressActionType.purgeSecretMessages => 'Стереть все секретные сообщения на устройстве',
        DuressActionType.wipePrivateVault => 'Стереть хранилище Private Mode',
        DuressActionType.lockPinUi => 'Временно запретить ввод PIN',
        DuressActionType.lockApp => 'Заблокировать всё приложение',
        DuressActionType.showDecoyOnly => 'Открыть безопасный (фейковый) интерфейс',
        DuressActionType.deactivateSecretSessions => 'Закрыть открытые секретные сессии',
        DuressActionType.none => '',
      };

  /// Actions shown in the builder catalog (no `none`).
  static const catalog = [
    DuressActionType.notifyTrustedChat,
    DuressActionType.relayEvent,
    DuressActionType.deleteChats,
    DuressActionType.purgeSecretMessages,
    DuressActionType.lockPinUi,
    DuressActionType.lockApp,
    DuressActionType.showDecoyOnly,
    DuressActionType.deactivateSecretSessions,
    DuressActionType.wipePrivateVault,
  ];

  static DuressActionType parse(String raw) => switch (raw) {
        'lock_pin_ui' => DuressActionType.lockPinUi,
        'lock_app' => DuressActionType.lockApp,
        'notify_trusted_chat' => DuressActionType.notifyTrustedChat,
        'relay_event' => DuressActionType.relayEvent,
        'purge_secret_messages' => DuressActionType.purgeSecretMessages,
        'wipe_private_vault' => DuressActionType.wipePrivateVault,
        'deactivate_secret_sessions' => DuressActionType.deactivateSecretSessions,
        'show_decoy_only' => DuressActionType.showDecoyOnly,
        'delete_chats' => DuressActionType.deleteChats,
        _ => DuressActionType.none,
      };
}

/// Which chats a [DuressActionType.deleteChats] targets.
enum DuressChatScope {
  specific,
  allSecret,
  allHidden,
  allDirect,
}

extension DuressChatScopeJson on DuressChatScope {
  String get wire => switch (this) {
        DuressChatScope.specific => 'specific',
        DuressChatScope.allSecret => 'all_secret',
        DuressChatScope.allHidden => 'all_hidden',
        DuressChatScope.allDirect => 'all_direct',
      };

  String get labelRu => switch (this) {
        DuressChatScope.specific => 'Выбранные чаты',
        DuressChatScope.allSecret => 'Все секретные чаты',
        DuressChatScope.allHidden => 'Все скрытые чаты',
        DuressChatScope.allDirect => 'Все личные чаты',
      };

  static DuressChatScope parse(String? raw) => switch (raw) {
        'all_secret' => DuressChatScope.allSecret,
        'all_hidden' => DuressChatScope.allHidden,
        'all_direct' => DuressChatScope.allDirect,
        _ => DuressChatScope.specific,
      };
}

enum DuressChatDeleteMode {
  clearHistory,
  removeLocal,
}

extension DuressChatDeleteModeJson on DuressChatDeleteMode {
  String get wire => switch (this) {
        DuressChatDeleteMode.clearHistory => 'clear_history',
        DuressChatDeleteMode.removeLocal => 'remove_local',
      };

  String get labelRu => switch (this) {
        DuressChatDeleteMode.clearHistory => 'Очистить историю (чат остаётся)',
        DuressChatDeleteMode.removeLocal => 'Убрать из списка + очистить',
      };

  static DuressChatDeleteMode parse(String? raw) => switch (raw) {
        'remove_local' => DuressChatDeleteMode.removeLocal,
        _ => DuressChatDeleteMode.clearHistory,
      };
}

class DuressAction {
  const DuressAction({
    required this.type,
    this.durationSec,
    this.uiCode,
    this.relayEvent,
    this.messageTemplate,
    this.conversationIds,
    this.chatScope,
    this.chatDeleteMode,
  });

  final DuressActionType type;
  final int? durationSec;
  final int? uiCode;
  final int? relayEvent;

  /// E2E plaintext for trusted notify. Supports `{name}`, `{threshold}`.
  final String? messageTemplate;

  final List<String>? conversationIds;
  final DuressChatScope? chatScope;
  final DuressChatDeleteMode? chatDeleteMode;

  static const defaultDangerTemplate =
      'Пользователь {name} несколько раз ввёл неверный PIN — возможно, он в опасности';

  DuressAction copyWith({
    DuressActionType? type,
    int? durationSec,
    int? uiCode,
    int? relayEvent,
    String? messageTemplate,
    List<String>? conversationIds,
    DuressChatScope? chatScope,
    DuressChatDeleteMode? chatDeleteMode,
  }) =>
      DuressAction(
        type: type ?? this.type,
        durationSec: durationSec ?? this.durationSec,
        uiCode: uiCode ?? this.uiCode,
        relayEvent: relayEvent ?? this.relayEvent,
        messageTemplate: messageTemplate ?? this.messageTemplate,
        conversationIds: conversationIds ?? this.conversationIds,
        chatScope: chatScope ?? this.chatScope,
        chatDeleteMode: chatDeleteMode ?? this.chatDeleteMode,
      );

  String resolveTemplate({required String name, int? threshold}) {
    final raw = (messageTemplate == null || messageTemplate!.trim().isEmpty)
        ? (uiCode != null ? DuressSignalLabels.forCode(uiCode!) : defaultDangerTemplate)
        : messageTemplate!;
    return raw
        .replaceAll('{name}', name)
        .replaceAll('{threshold}', '${threshold ?? ''}');
  }

  Map<String, dynamic> toJson() => {
        'type': type.wire,
        if (durationSec != null) 'duration_sec': durationSec,
        if (uiCode != null) 'ui_code': uiCode,
        if (relayEvent != null) 'event': relayEvent,
        if (messageTemplate != null && messageTemplate!.isNotEmpty) 'message_template': messageTemplate,
        if (conversationIds != null && conversationIds!.isNotEmpty) 'conversation_ids': conversationIds,
        if (chatScope != null) 'chat_scope': chatScope!.wire,
        if (chatDeleteMode != null) 'chat_delete_mode': chatDeleteMode!.wire,
      };

  factory DuressAction.fromJson(Map<String, dynamic> json) => DuressAction(
        type: DuressActionTypeJson.parse(json['type'] as String? ?? 'none'),
        durationSec: json['duration_sec'] as int?,
        uiCode: json['ui_code'] as int?,
        relayEvent: json['event'] as int?,
        messageTemplate: json['message_template'] as String?,
        conversationIds: (json['conversation_ids'] as List<dynamic>?)?.cast<String>(),
        chatScope: json['chat_scope'] != null
            ? DuressChatScopeJson.parse(json['chat_scope'] as String?)
            : null,
        chatDeleteMode: json['chat_delete_mode'] != null
            ? DuressChatDeleteModeJson.parse(json['chat_delete_mode'] as String?)
            : null,
      );
}

class DuressRule {
  const DuressRule({
    required this.trigger,
    required this.threshold,
    required this.actions,
    this.windowSec = 86400,
    this.channels,
  });

  final DuressTrigger trigger;
  final int threshold;
  final int windowSec;
  final List<DuressAction> actions;

  /// Per-rule delivery override; `null` = global [DuressPolicyData.trustedChannels].
  final List<String>? channels;

  DuressRule copyWith({
    DuressTrigger? trigger,
    int? threshold,
    int? windowSec,
    List<DuressAction>? actions,
    List<String>? channels,
    bool clearChannels = false,
  }) =>
      DuressRule(
        trigger: trigger ?? this.trigger,
        threshold: threshold ?? this.threshold,
        windowSec: windowSec ?? this.windowSec,
        actions: actions ?? List.from(this.actions),
        channels: clearChannels ? null : (channels ?? this.channels),
      );

  String get summaryRu {
    final actionText = actions.map((a) => a.type.labelRu).join(' → ');
    final ch = channels == null ? '' : ' · ${DuressTrustedChannels.label(channels!)}';
    return 'После ${trigger.labelRu} ×$threshold · $actionText$ch';
  }

  Map<String, dynamic> toJson() => {
        'trigger': trigger.wire,
        'threshold': threshold,
        'window_sec': windowSec,
        if (channels != null) 'channels': channels,
        'actions': actions.map((a) => a.toJson()).toList(),
      };

  factory DuressRule.fromJson(Map<String, dynamic> json) {
    final trigger = DuressTriggerJson.parse(json['trigger'] as String?) ?? DuressTrigger.pinUnlockFail;
    final actionsRaw = json['actions'] as List<dynamic>? ?? [];
    final channelsRaw = json['channels'] as List<dynamic>?;
    return DuressRule(
      trigger: trigger,
      threshold: json['threshold'] as int? ?? 1,
      windowSec: json['window_sec'] as int? ?? 86400,
      channels: channelsRaw?.cast<String>(),
      actions: actionsRaw.map((e) => DuressAction.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
}

class DuressCounter {
  DuressCounter({this.count = 0, DateTime? windowStart}) : windowStart = windowStart ?? DateTime.now();

  int count;
  DateTime windowStart;

  Map<String, dynamic> toJson() => {
        'count': count,
        'window_start': windowStart.toIso8601String(),
      };

  factory DuressCounter.fromJson(Map<String, dynamic> json) => DuressCounter(
        count: json['count'] as int? ?? 0,
        windowStart: DateTime.tryParse(json['window_start'] as String? ?? '') ?? DateTime.now(),
      );
}

class DuressPolicyData {
  DuressPolicyData({
    this.version = 1,
    this.presetId = DuressPresets.customId,
    List<String>? trustedUserIds,
    List<String>? trustedChannels,
    List<DuressRule>? rules,
    Map<String, DuressCounter>? counters,
    this.lockoutUntil,
  })  : trustedUserIds = trustedUserIds ?? [],
        trustedChannels = trustedChannels ?? const ['chat', 'relay'],
        rules = rules ?? List.from(DuressPresets.defaultSeedRules),
        counters = counters ?? {};

  final int version;
  String presetId;
  List<String> trustedUserIds;
  List<String> trustedChannels;
  List<DuressRule> rules;
  Map<String, DuressCounter> counters;
  DateTime? lockoutUntil;

  bool get hasNotifyRecipe =>
      rules.any((r) => r.actions.any((a) => a.type == DuressActionType.notifyTrustedChat));

  Map<String, dynamic> toJson() => {
        'v': version,
        'preset_id': presetId,
        'trusted_user_ids': trustedUserIds,
        'trusted_channels': trustedChannels,
        'rules': rules.map((r) => r.toJson()).toList(),
        'counters': counters.map((k, v) => MapEntry(k, v.toJson())),
        if (lockoutUntil != null) 'lockout_until': lockoutUntil!.toIso8601String(),
      };

  factory DuressPolicyData.fromJson(Map<String, dynamic> json) {
    final countersRaw = json['counters'] as Map<String, dynamic>? ?? {};
    final rulesRaw = json['rules'] as List<dynamic>?;
    final presetId = json['preset_id'] as String? ?? DuressPresets.customId;
    return DuressPolicyData(
      version: json['v'] as int? ?? 1,
      presetId: presetId,
      trustedUserIds: (json['trusted_user_ids'] as List<dynamic>? ?? []).cast<String>(),
      trustedChannels: (json['trusted_channels'] as List<dynamic>? ?? ['chat', 'relay']).cast<String>(),
      rules: rulesRaw != null
          ? rulesRaw.map((e) => DuressRule.fromJson(e as Map<String, dynamic>)).toList()
          : (presetId == DuressPresets.customId
              ? List.from(DuressPresets.defaultSeedRules)
              : DuressPresets.rulesFor(presetId)),
      counters: countersRaw.map((k, v) => MapEntry(k, DuressCounter.fromJson(v as Map<String, dynamic>))),
      lockoutUntil: DateTime.tryParse(json['lockout_until'] as String? ?? ''),
    );
  }

  factory DuressPolicyData.withDefaults() => DuressPolicyData(
        presetId: DuressPresets.customId,
        rules: List.from(DuressPresets.defaultSeedRules),
      );

  /// Legacy helper — maps old preset ids into concrete rule lists.
  factory DuressPolicyData.withPreset(String presetId) {
    if (presetId == DuressPresets.customId) {
      return DuressPolicyData.withDefaults();
    }
    return DuressPolicyData(
      presetId: DuressPresets.customId,
      rules: List.from(DuressPresets.rulesFor(presetId)),
    );
  }

  DuressCounter counterFor(DuressTrigger trigger) {
    final key = trigger.wire;
    return counters.putIfAbsent(key, DuressCounter.new);
  }

  /// Convert legacy P1–P4 into custom recipes once.
  bool migratePresetsToCustom() {
    if (presetId == DuressPresets.customId) return false;
    if (DuressPresets.legacyIds.contains(presetId)) {
      if (rules.isEmpty) {
        rules = List.from(DuressPresets.rulesFor(presetId));
      }
      presetId = DuressPresets.customId;
      return true;
    }
    presetId = DuressPresets.customId;
    return true;
  }
}

/// Seeds / optional recipe templates — not mode switches.
class DuressPresets {
  DuressPresets._();

  static const customId = 'custom';
  static const legacyIds = ['P1', 'P2', 'P3', 'P4'];

  /// Kept for migration only.
  static const ids = ['P1', 'P2', 'P3', 'P4', 'custom'];

  static String label(String id) => switch (id) {
        'P1' => 'Минимальный (шаблон)',
        'P2' => 'С доверенными (шаблон)',
        'P3' => 'Параноидальный (шаблон)',
        'P4' => 'Тихий decoy (шаблон)',
        'custom' => 'Свои рецепты',
        _ => id,
      };

  static String description(String id) => switch (id) {
        'P1' => 'Добавит набор: блокировка и decoy',
        'P2' => 'Добавит набор: уведомления и purge',
        'P3' => 'Добавит агрессивный набор',
        'P4' => 'Добавит тихий decoy-набор',
        'custom' => 'Список ваших рецептов',
        _ => '',
      };

  /// Factory seed when policy is first created.
  static const defaultSeedRules = [
    DuressRule(
      trigger: DuressTrigger.decoyPinStreak,
      threshold: 5,
      windowSec: 86400,
      actions: [
        DuressAction(
          type: DuressActionType.notifyTrustedChat,
          uiCode: 30,
          messageTemplate: DuressAction.defaultDangerTemplate,
        ),
        DuressAction(type: DuressActionType.relayEvent, relayEvent: 30),
      ],
    ),
  ];

  /// Optional one-shot templates the user can add (append, not replace).
  static List<DuressRule> templatePack(String id) => rulesFor(id);

  static List<DuressRule> rulesFor(String presetId) {
    if (presetId == customId) {
      return List.from(defaultSeedRules);
    }
    return switch (presetId) {
      'P1' => List.from(_p1),
      'P3' => List.from(_p3),
      'P4' => List.from(_p4),
      _ => List.from(_p2),
    };
  }

  static const _p1 = [
    DuressRule(
      trigger: DuressTrigger.pinUnlockFail,
      threshold: 5,
      windowSec: 300,
      actions: [DuressAction(type: DuressActionType.lockPinUi, durationSec: 300)],
    ),
    DuressRule(
      trigger: DuressTrigger.decoyPinStreak,
      threshold: 1,
      actions: [DuressAction(type: DuressActionType.showDecoyOnly)],
    ),
  ];

  static const _p2 = [
    DuressRule(
      trigger: DuressTrigger.decoyPinStreak,
      threshold: 1,
      actions: [
        DuressAction(type: DuressActionType.notifyTrustedChat, uiCode: 20),
        DuressAction(type: DuressActionType.relayEvent, relayEvent: 20),
        DuressAction(type: DuressActionType.deactivateSecretSessions),
        DuressAction(type: DuressActionType.showDecoyOnly),
      ],
    ),
    DuressRule(
      trigger: DuressTrigger.decoyPinStreak,
      threshold: 3,
      actions: [
        DuressAction(type: DuressActionType.notifyTrustedChat, uiCode: 30),
        DuressAction(type: DuressActionType.relayEvent, relayEvent: 30),
      ],
    ),
    DuressRule(
      trigger: DuressTrigger.decoyPinStreak,
      threshold: 5,
      actions: [
        DuressAction(type: DuressActionType.purgeSecretMessages),
        DuressAction(
          type: DuressActionType.notifyTrustedChat,
          uiCode: 40,
          messageTemplate: DuressAction.defaultDangerTemplate,
        ),
        DuressAction(type: DuressActionType.relayEvent, relayEvent: 40),
      ],
    ),
    DuressRule(
      trigger: DuressTrigger.pinUnlockFail,
      threshold: 3,
      windowSec: 300,
      actions: [
        DuressAction(type: DuressActionType.notifyTrustedChat, uiCode: 10),
        DuressAction(type: DuressActionType.relayEvent, relayEvent: 10),
      ],
    ),
    DuressRule(
      trigger: DuressTrigger.pinUnlockFail,
      threshold: 5,
      windowSec: 300,
      actions: [DuressAction(type: DuressActionType.lockPinUi, durationSec: 300)],
    ),
    DuressRule(
      trigger: DuressTrigger.panicExit,
      threshold: 1,
      actions: [DuressAction(type: DuressActionType.deactivateSecretSessions)],
    ),
    DuressRule(
      trigger: DuressTrigger.emergencyLock,
      threshold: 1,
      actions: [
        DuressAction(type: DuressActionType.notifyTrustedChat, uiCode: 40),
        DuressAction(type: DuressActionType.relayEvent, relayEvent: 40),
        DuressAction(type: DuressActionType.deactivateSecretSessions),
      ],
    ),
  ];

  static const _p3 = [
    DuressRule(
      trigger: DuressTrigger.pinUnlockFail,
      threshold: 1,
      actions: [DuressAction(type: DuressActionType.relayEvent, relayEvent: 10)],
    ),
    DuressRule(
      trigger: DuressTrigger.pinUnlockFail,
      threshold: 3,
      windowSec: 300,
      actions: [
        DuressAction(type: DuressActionType.lockPinUi, durationSec: 900),
        DuressAction(type: DuressActionType.relayEvent, relayEvent: 30),
      ],
    ),
    DuressRule(
      trigger: DuressTrigger.decoyPinStreak,
      threshold: 1,
      actions: [
        DuressAction(type: DuressActionType.purgeSecretMessages),
        DuressAction(type: DuressActionType.relayEvent, relayEvent: 40),
        DuressAction(type: DuressActionType.showDecoyOnly),
      ],
    ),
    DuressRule(
      trigger: DuressTrigger.secretRoomActivateFail,
      threshold: 3,
      windowSec: 3600,
      actions: [DuressAction(type: DuressActionType.relayEvent, relayEvent: 10)],
    ),
    DuressRule(
      trigger: DuressTrigger.panicExit,
      threshold: 1,
      actions: [
        DuressAction(type: DuressActionType.deactivateSecretSessions),
        DuressAction(type: DuressActionType.relayEvent, relayEvent: 30),
      ],
    ),
    DuressRule(
      trigger: DuressTrigger.emergencyLock,
      threshold: 1,
      actions: [
        DuressAction(type: DuressActionType.purgeSecretMessages),
        DuressAction(type: DuressActionType.relayEvent, relayEvent: 40),
      ],
    ),
  ];

  static const _p4 = [
    DuressRule(
      trigger: DuressTrigger.decoyPinStreak,
      threshold: 1,
      actions: [DuressAction(type: DuressActionType.showDecoyOnly)],
    ),
    DuressRule(
      trigger: DuressTrigger.pinUnlockFail,
      threshold: 10,
      windowSec: 600,
      actions: [DuressAction(type: DuressActionType.lockPinUi, durationSec: 60)],
    ),
  ];
}

class DuressTrustedChannels {
  DuressTrustedChannels._();

  static const chatOnly = ['chat'];
  static const relayOnly = ['relay'];
  static const both = ['chat', 'relay'];

  static String label(List<String> channels) {
    if (channels.contains('both') || (channels.contains('chat') && channels.contains('relay'))) {
      return 'Оба канала';
    }
    if (channels.contains('relay')) return 'Только сервер (relay)';
    return 'Только чат (E2E)';
  }

  static String description(List<String> channels) {
    if (channels.contains('both') || (channels.contains('chat') && channels.contains('relay'))) {
      return 'E2E-сообщение и серверный relay';
    }
    if (channels.contains('relay')) return 'Только POST /security-signals';
    return 'Зашифрованное сообщение в личный чат';
  }

  static List<String> normalize(List<String> channels) {
    if (channels.contains('both')) return List.from(both);
    final out = <String>[];
    if (channels.contains('chat')) out.add('chat');
    if (channels.contains('relay')) out.add('relay');
    return out.isEmpty ? List.from(both) : out;
  }
}

class DuressSignalLabels {
  static String forCode(int code) => switch (code) {
        10 => 'Подозрительная активность PIN у контакта',
        20 => 'Контакт мог использовать дополнительный PIN',
        30 => 'Возможное принуждение — проверьте контакт',
        40 => 'Критический сигнал безопасности контакта',
        90 => 'Тест доставки сигнала',
        _ => 'Техническое уведомление ($code)',
      };
}

class DuressHandleResult {
  const DuressHandleResult({
    this.openDecoy = false,
    this.lockoutUntil,
    this.purgedSecrets = false,
    this.lockApp = false,
  });

  final bool openDecoy;
  final DateTime? lockoutUntil;
  final bool purgedSecrets;
  final bool lockApp;
}
