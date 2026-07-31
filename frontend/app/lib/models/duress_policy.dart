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

  /// Triggers users can assign in custom rules.
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
      };

  String get labelRu => switch (this) {
        DuressActionType.none => 'Ничего',
        DuressActionType.lockPinUi => 'Блокировка ввода PIN',
        DuressActionType.lockApp => 'Блокировка приложения',
        DuressActionType.notifyTrustedChat => 'Уведомление в чат',
        DuressActionType.relayEvent => 'Сигнал через сервер',
        DuressActionType.purgeSecretMessages => 'Удалить secret-сообщения',
        DuressActionType.wipePrivateVault => 'Очистить Private Mode',
        DuressActionType.deactivateSecretSessions => 'Сброс secret-сессий',
        DuressActionType.showDecoyOnly => 'Только decoy-интерфейс',
      };

  static DuressActionType parse(String raw) => switch (raw) {
        'lock_pin_ui' => DuressActionType.lockPinUi,
        'lock_app' => DuressActionType.lockApp,
        'notify_trusted_chat' => DuressActionType.notifyTrustedChat,
        'relay_event' => DuressActionType.relayEvent,
        'purge_secret_messages' => DuressActionType.purgeSecretMessages,
        'wipe_private_vault' => DuressActionType.wipePrivateVault,
        'deactivate_secret_sessions' => DuressActionType.deactivateSecretSessions,
        'show_decoy_only' => DuressActionType.showDecoyOnly,
        _ => DuressActionType.none,
      };
}

class DuressAction {
  const DuressAction({
    required this.type,
    this.durationSec,
    this.uiCode,
    this.relayEvent,
  });

  final DuressActionType type;
  final int? durationSec;
  final int? uiCode;
  final int? relayEvent;

  Map<String, dynamic> toJson() => {
        'type': type.wire,
        if (durationSec != null) 'duration_sec': durationSec,
        if (uiCode != null) 'ui_code': uiCode,
        if (relayEvent != null) 'event': relayEvent,
      };

  factory DuressAction.fromJson(Map<String, dynamic> json) => DuressAction(
        type: DuressActionTypeJson.parse(json['type'] as String? ?? 'none'),
        durationSec: json['duration_sec'] as int?,
        uiCode: json['ui_code'] as int?,
        relayEvent: json['event'] as int?,
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
    final actionText = actions.map((a) => a.type.labelRu).join(', ');
    final ch = channels == null ? '' : ' · ${DuressTrustedChannels.label(channels!)}';
    return '${trigger.labelRu} ×$threshold · $actionText$ch';
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
    this.presetId = 'P2',
    List<String>? trustedUserIds,
    List<String>? trustedChannels,
    List<DuressRule>? rules,
    Map<String, DuressCounter>? counters,
    this.lockoutUntil,
  })  : trustedUserIds = trustedUserIds ?? [],
        trustedChannels = trustedChannels ?? const ['chat', 'relay'],
        rules = rules ?? DuressPresets.rulesFor('P2'),
        counters = counters ?? {};

  final int version;
  String presetId;
  List<String> trustedUserIds;
  List<String> trustedChannels;
  List<DuressRule> rules;
  Map<String, DuressCounter> counters;
  DateTime? lockoutUntil;

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
    final presetId = json['preset_id'] as String? ?? 'P2';
    return DuressPolicyData(
      version: json['v'] as int? ?? 1,
      presetId: presetId,
      trustedUserIds: (json['trusted_user_ids'] as List<dynamic>? ?? []).cast<String>(),
      trustedChannels: (json['trusted_channels'] as List<dynamic>? ?? ['chat', 'relay']).cast<String>(),
      rules: rulesRaw != null
          ? rulesRaw.map((e) => DuressRule.fromJson(e as Map<String, dynamic>)).toList()
          : DuressPresets.rulesFor(presetId),
      counters: countersRaw.map((k, v) => MapEntry(k, DuressCounter.fromJson(v as Map<String, dynamic>))),
      lockoutUntil: DateTime.tryParse(json['lockout_until'] as String? ?? ''),
    );
  }

  factory DuressPolicyData.withPreset(String presetId) => DuressPolicyData(
        presetId: presetId,
        rules: DuressPresets.rulesFor(presetId),
      );

  DuressCounter counterFor(DuressTrigger trigger) {
    final key = trigger.wire;
    return counters.putIfAbsent(key, DuressCounter.new);
  }
}

/// Factory presets P1–P4 — spec/0404_DURESS_POLICY.md
class DuressPresets {
  DuressPresets._();

  static const ids = ['P1', 'P2', 'P3', 'P4', 'custom'];

  static const customId = 'custom';

  static String label(String id) => switch (id) {
        'P1' => 'Минимальный',
        'P2' => 'С доверенными',
        'P3' => 'Параноидальный',
        'P4' => 'Тихий decoy',
        'custom' => 'Своя',
        _ => id,
      };

  static String description(String id) => switch (id) {
        'P1' => 'Блокировка после 5 ошибок; decoy без уведомлений',
        'P2' => 'Уведомления доверенным; purge secret на 5× decoy',
        'P3' => 'Агрессивные сигналы и ранняя очистка',
        'P4' => 'Только decoy-режим, без оповещений',
        'custom' => 'Свой набор правил — вы сами задаёте пороги и действия',
        _ => '',
      };

  static List<DuressRule> rulesFor(String presetId) {
    if (presetId == customId) {
      throw StateError('Custom preset keeps rules in vault — do not call rulesFor(custom)');
    }
    return switch (presetId) {
      'P1' => _p1,
      'P3' => _p3,
      'P4' => _p4,
      _ => _p2,
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
        DuressAction(type: DuressActionType.notifyTrustedChat, uiCode: 40),
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

/// Delivery channel presets for trusted notifications — spec/0404 phase 2.
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

/// UI labels for duress codes (receiver client only).
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
  });

  final bool openDecoy;
  final DateTime? lockoutUntil;
  final bool purgedSecrets;
}
