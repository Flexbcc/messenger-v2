/// Catalog of screenshot states: group + id + Russian title.
class ScreenshotState {
  const ScreenshotState({
    required this.group,
    required this.id,
    required this.titleRu,
    this.skipped = false,
    this.skipReason,
  });

  final String group;
  final String id;
  final String titleRu;
  final bool skipped;
  final String? skipReason;

  String get fileStem => '${group}__$id';
}

const kScreenshotStates = <ScreenshotState>[
  // —— Chat ——
  ScreenshotState(group: 'chat', id: 'empty', titleRu: 'Чат пустой'),
  ScreenshotState(group: 'chat', id: 'loading_history', titleRu: 'Загрузка истории'),
  ScreenshotState(group: 'chat', id: 'unreachable', titleRu: 'Собеседник недоступен'),
  ScreenshotState(group: 'chat', id: 'offline', titleRu: 'Нет соединения (WS)'),
  ScreenshotState(group: 'chat', id: 'secret_banner', titleRu: 'Секретный сеанс'),
  ScreenshotState(group: 'chat', id: 'typing', titleRu: 'Индикатор набора'),
  ScreenshotState(group: 'chat', id: 'composer_reply', titleRu: 'Ответ в композере'),
  ScreenshotState(group: 'chat', id: 'date_separator', titleRu: 'Разделитель даты'),
  ScreenshotState(group: 'chat', id: 'msg_incoming_text', titleRu: 'Входящее текстовое'),
  ScreenshotState(group: 'chat', id: 'msg_decrypt_failed', titleRu: 'Не удалось расшифровать'),
  ScreenshotState(group: 'chat', id: 'msg_pending', titleRu: 'Статус: pending'),
  ScreenshotState(group: 'chat', id: 'msg_sending', titleRu: 'Статус: sending'),
  ScreenshotState(group: 'chat', id: 'msg_sent', titleRu: 'Статус: sent'),
  ScreenshotState(group: 'chat', id: 'msg_relay', titleRu: 'Статус: relay'),
  ScreenshotState(group: 'chat', id: 'msg_gateway', titleRu: 'Статус: gateway'),
  ScreenshotState(group: 'chat', id: 'msg_delivered', titleRu: 'Статус: delivered'),
  ScreenshotState(group: 'chat', id: 'msg_read', titleRu: 'Статус: read'),
  ScreenshotState(group: 'chat', id: 'msg_failed', titleRu: 'Статус: failed'),
  ScreenshotState(group: 'chat', id: 'msg_reply_quote', titleRu: 'Цитата ответа'),
  ScreenshotState(group: 'chat', id: 'msg_pinned', titleRu: 'Закреплённое сообщение'),
  ScreenshotState(group: 'chat', id: 'msg_highlighted', titleRu: 'Подсветка поиска'),
  ScreenshotState(group: 'chat', id: 'msg_file', titleRu: 'Файл'),
  ScreenshotState(group: 'chat', id: 'msg_image_placeholder', titleRu: 'Фото (плейсхолдер)'),
  ScreenshotState(group: 'chat', id: 'msg_video_placeholder', titleRu: 'Видео (плейсхолдер)'),
  ScreenshotState(group: 'chat', id: 'duress_banner', titleRu: 'Duress-баннер'),
  ScreenshotState(
    group: 'chat',
    id: 'voice_recording',
    titleRu: 'Запись голосового',
    skipped: true,
    skipReason: 'UI записи голоса ещё нет',
  ),

  // —— Call live ——
  ScreenshotState(group: 'call', id: 'outgoing_ringing', titleRu: 'Исходящий — звоним'),
  ScreenshotState(group: 'call', id: 'incoming_ringing', titleRu: 'Входящий — звонок'),
  ScreenshotState(group: 'call', id: 'active_audio', titleRu: 'Активный аудиозвонок'),
  ScreenshotState(group: 'call', id: 'active_video', titleRu: 'Активный видеозвонок'),
  ScreenshotState(group: 'call', id: 'active_muted', titleRu: 'Микрофон выкл.'),
  ScreenshotState(group: 'call', id: 'active_speaker', titleRu: 'Громкая связь'),
  ScreenshotState(group: 'call', id: 'active_hold', titleRu: 'На удержании'),
  ScreenshotState(group: 'call', id: 'waiting_network', titleRu: 'Ожидание сети'),
  ScreenshotState(group: 'call', id: 'minimized', titleRu: 'Свёрнутый звонок'),
  ScreenshotState(group: 'call', id: 'ended', titleRu: 'Звонок завершён'),

  // —— Calls history ——
  ScreenshotState(group: 'calls', id: 'empty_all', titleRu: 'История пуста'),
  ScreenshotState(group: 'calls', id: 'empty_missed', titleRu: 'Нет пропущенных'),
  ScreenshotState(group: 'calls', id: 'row_completed_out', titleRu: 'Завершён исходящий'),
  ScreenshotState(group: 'calls', id: 'row_missed_in', titleRu: 'Пропущенный входящий'),
  ScreenshotState(group: 'calls', id: 'row_cancelled_out', titleRu: 'Отменён'),
  ScreenshotState(group: 'calls', id: 'row_rejected_in', titleRu: 'Отклонён'),
  ScreenshotState(group: 'calls', id: 'row_busy', titleRu: 'Занято'),
  ScreenshotState(group: 'calls', id: 'row_failed', titleRu: 'Ошибка'),
  ScreenshotState(group: 'calls', id: 'row_video_out', titleRu: 'Видео исходящий'),

  // —— Conversation list ——
  ScreenshotState(group: 'conv_list', id: 'empty', titleRu: 'Список чатов пуст'),
  ScreenshotState(group: 'conv_list', id: 'populated', titleRu: 'Чаты с unread/draft/mute'),
  ScreenshotState(group: 'conv_list', id: 'search_empty', titleRu: 'Поиск без результатов'),

  // —— Contacts ——
  ScreenshotState(group: 'contacts', id: 'empty', titleRu: 'Контакты пусты'),
  ScreenshotState(group: 'contacts', id: 'list', titleRu: 'Список контактов'),

  // —— Devices ——
  ScreenshotState(group: 'devices', id: 'loading', titleRu: 'Устройства — загрузка'),
  ScreenshotState(group: 'devices', id: 'error', titleRu: 'Устройства — ошибка'),
  ScreenshotState(group: 'devices', id: 'empty', titleRu: 'Устройства — пусто'),
  ScreenshotState(group: 'devices', id: 'list', titleRu: 'Список устройств'),

  // —— Auth / lock ——
  ScreenshotState(group: 'auth', id: 'onboarding_idle', titleRu: 'Онбординг'),
  ScreenshotState(group: 'auth', id: 'login_idle', titleRu: 'Вход'),
  ScreenshotState(group: 'auth', id: 'login_loading', titleRu: 'Вход — загрузка'),
  ScreenshotState(group: 'auth', id: 'login_error', titleRu: 'Вход — ошибка'),
  ScreenshotState(group: 'auth', id: 'app_lock_pin', titleRu: 'Блокировка PIN'),
  ScreenshotState(group: 'auth', id: 'app_lock_wrong', titleRu: 'Неверный PIN'),
  ScreenshotState(group: 'auth', id: 'pin_setup_enter', titleRu: 'Создание PIN'),

  // —— Settings & misc ——
  ScreenshotState(group: 'settings', id: 'hub', titleRu: 'Хаб настроек'),
  ScreenshotState(group: 'settings', id: 'appearance', titleRu: 'Оформление'),
  ScreenshotState(group: 'settings', id: 'notifications', titleRu: 'Уведомления'),
  ScreenshotState(group: 'profile', id: 'home', titleRu: 'Профиль'),
  ScreenshotState(group: 'storage', id: 'home', titleRu: 'Хранилище данных'),
  ScreenshotState(group: 'hidden', id: 'empty', titleRu: 'Скрытые чаты пусты'),
  ScreenshotState(group: 'security', id: 'emergency_lock', titleRu: 'Экстренная блокировка'),
];
