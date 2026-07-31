import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:messenger_app/calls/call_signal.dart';
import 'package:messenger_app/core/ui/chat_list_tile.dart';
import 'package:messenger_app/models/message.dart';
import 'package:messenger_app/models/message_delivery_info.dart';
import 'package:messenger_app/state/app_controller.dart';
import 'package:messenger_app/theme/colors.dart';
import 'package:messenger_app/theme/spacing.dart';
import 'package:messenger_app/theme/typography.dart';
import 'package:messenger_app/utils/message_grouping.dart';
import 'package:messenger_app/widgets/call_stage.dart';
import 'package:messenger_app/widgets/chat/chat_message_bubble.dart';
import 'package:messenger_app/widgets/chat/duress_signal_banner.dart';

import 'states_manifest.dart';

Widget wrapScreenshot(Widget child, {AppController? controller}) {
  final c = controller ?? AppController();
  return ProviderScope(
    overrides: [appControllerProvider.overrideWith((ref) => c)],
    child: Scaffold(body: child),
  );
}

MessageGroupLayout _solo(ChatMessage m) => MessageGroupLayout(
      message: m,
      isFirstInGroup: true,
      isLastInGroup: true,
      showGroupTime: true,
      showDateSeparator: false,
      showPauseSeparator: false,
    );

ChatMessage _msg({
  required String id,
  required bool mine,
  String contentType = 'text',
  String? plaintext,
  bool decryptFailed = false,
  String? replyPreview,
  String? systemKind,
  int? duressCode,
}) {
  return ChatMessage(
    id: id,
    conversationId: 'c1',
    senderUserId: mine ? 'me' : 'peer',
    senderDeviceId: 'd1',
    ciphertext: 'x',
    contentType: contentType,
    cryptoVersion: '1',
    createdAt: DateTime.utc(2026, 7, 19, 12, 0),
    plaintext: plaintext,
    decryptFailed: decryptFailed,
    replyPreview: replyPreview,
    systemKind: systemKind,
    duressCode: duressCode,
  );
}

Widget buildScreenshotScene(ScreenshotState state) {
  switch ('${state.group}/${state.id}') {
    // —— Chat chrome ——
    case 'chat/empty':
      return wrapScreenshot(_ChatFrame(
        body: const Center(child: Text('Нет сообщений', style: TextStyle(color: Colors.white54))),
      ));
    case 'chat/loading_history':
      return wrapScreenshot(_ChatFrame(
        body: const Center(child: Icon(Icons.hourglass_top, color: Colors.white54, size: 40)),
      ));
    case 'chat/unreachable':
      return wrapScreenshot(_ChatFrame(
        banner: _Banner(color: AppColors.dangerRed, text: 'Собеседник недоступен'),
        body: const SizedBox.shrink(),
      ));
    case 'chat/offline':
      return wrapScreenshot(_ChatFrame(
        banner: _Banner(color: AppColors.warningYellow, text: 'Нет соединения с сетью'),
        body: const SizedBox.shrink(),
      ));
    case 'chat/secret_banner':
      return wrapScreenshot(_ChatFrame(
        banner: _Banner(color: AppColors.accentBlue, text: '🔒 Секретный чат активен'),
        body: _bubblePane([
          ChatMessageBubble(
            message: _msg(id: '1', mine: false, plaintext: 'Секретное сообщение'),
            isMine: false,
            layout: _solo(_msg(id: '1', mine: false, plaintext: 'Секретное сообщение')),
          ),
        ]),
      ));
    case 'chat/typing':
      return wrapScreenshot(_ChatFrame(
        body: Column(
          children: [
            Expanded(child: _bubblePane([
              ChatMessageBubble(
                message: _msg(id: '1', mine: false, plaintext: 'Привет'),
                isMine: false,
                layout: _solo(_msg(id: '1', mine: false, plaintext: 'Привет')),
              ),
            ])),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('печатает…', style: TextStyle(color: Colors.white54, fontStyle: FontStyle.italic)),
              ),
            ),
          ],
        ),
      ));
    case 'chat/composer_reply':
      return wrapScreenshot(_ChatFrame(
        body: Column(
          children: [
            Expanded(child: _bubblePane([])),
            Container(
              color: AppColors.surfaceDark,
              padding: const EdgeInsets.all(12),
              child: const Row(
                children: [
                  Icon(Icons.reply, color: AppColors.accentBlue, size: 18),
                  SizedBox(width: 8),
                  Expanded(child: Text('Ответ: Встретимся в 18:00', style: TextStyle(color: Colors.white70))),
                  Icon(Icons.close, color: Colors.white54, size: 18),
                ],
              ),
            ),
            _fakeComposer(),
          ],
        ),
      ));
    case 'chat/date_separator':
      return wrapScreenshot(_ChatFrame(
        body: _bubblePane(const [
          ChatTimeSeparator(label: 'Сегодня'),
        ]),
      ));
    case 'chat/duress_banner':
      return wrapScreenshot(_ChatFrame(
        body: const DuressSignalBanner(code: 30),
      ));

    // —— Chat bubbles / statuses ——
    case 'chat/msg_incoming_text':
      return _bubbleShot(message: _msg(id: '1', mine: false, plaintext: 'Привет! Как дела?'));
    case 'chat/msg_decrypt_failed':
      return _bubbleShot(message: _msg(id: '1', mine: false, decryptFailed: true));
    case 'chat/msg_pending':
      return _bubbleShot(message: _msg(id: '1', mine: true, plaintext: 'Отправляется…'), status: MessageDeliveryStatus.pending);
    case 'chat/msg_sending':
      return _bubbleShot(message: _msg(id: '1', mine: true, plaintext: 'Отправка'), status: MessageDeliveryStatus.sending);
    case 'chat/msg_sent':
      return _bubbleShot(message: _msg(id: '1', mine: true, plaintext: 'Ушло на сервер'), status: MessageDeliveryStatus.sent);
    case 'chat/msg_relay':
      return _bubbleShot(message: _msg(id: '1', mine: true, plaintext: 'Через relay'), status: MessageDeliveryStatus.relay);
    case 'chat/msg_gateway':
      return _bubbleShot(message: _msg(id: '1', mine: true, plaintext: 'Через gateway'), status: MessageDeliveryStatus.gateway);
    case 'chat/msg_delivered':
      return _bubbleShot(message: _msg(id: '1', mine: true, plaintext: 'Доставлено'), status: MessageDeliveryStatus.delivered);
    case 'chat/msg_read':
      return _bubbleShot(message: _msg(id: '1', mine: true, plaintext: 'Прочитано'), status: MessageDeliveryStatus.read);
    case 'chat/msg_failed':
      return _bubbleShot(
        message: _msg(id: '1', mine: true, plaintext: 'Не отправилось'),
        status: MessageDeliveryStatus.failed,
        deliveryError: 'timeout',
      );
    case 'chat/msg_reply_quote':
      return _bubbleShot(message: _msg(id: '1', mine: true, plaintext: 'Ок', replyPreview: 'Встретимся в 18:00'));
    case 'chat/msg_pinned':
      return _bubbleShot(message: _msg(id: '1', mine: false, plaintext: 'Важное'), pinned: true);
    case 'chat/msg_highlighted':
      return _bubbleShot(message: _msg(id: '1', mine: false, plaintext: 'Найденное'), highlighted: true);
    case 'chat/msg_file':
      return wrapScreenshot(_ChatFrame(
        body: _bubblePane([
          Card(
            child: ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: const Text('report.pdf'),
              subtitle: const Text('12 КБ'),
              trailing: Icon(Icons.check, color: Colors.lightBlue.shade200),
            ),
          ),
        ]),
      ));
    case 'chat/msg_image_placeholder':
      return wrapScreenshot(_ChatFrame(
        body: _bubblePane([
          Container(
            height: 180,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.image, size: 48, color: Colors.white38),
          ),
        ]),
      ));
    case 'chat/msg_video_placeholder':
      return wrapScreenshot(_ChatFrame(
        body: _bubblePane([
          Container(
            height: 180,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.play_circle_outline, size: 48, color: Colors.white38),
          ),
        ]),
      ));

    // —— Call ——
    case 'call/outgoing_ringing':
      return wrapScreenshot(CallStage(
        peerName: 'Анна',
        kind: CallKind.audio,
        outgoing: true,
        answered: false,
        onCancel: () {},
      ));
    case 'call/incoming_ringing':
      return wrapScreenshot(CallStage(
        peerName: 'Анна',
        kind: CallKind.audio,
        outgoing: false,
        answered: false,
        onReject: () {},
        onAnswer: () {},
      ));
    case 'call/active_audio':
      return wrapScreenshot(CallStage(
        peerName: 'Анна',
        kind: CallKind.audio,
        outgoing: true,
        answered: true,
        elapsed: const Duration(minutes: 1, seconds: 23),
        onToggleMute: () {},
        onToggleSpeaker: () {},
        onToggleHold: () {},
        onEnd: () {},
        onMinimize: () {},
      ));
    case 'call/active_video':
      return wrapScreenshot(CallStage(
        peerName: 'Анна',
        kind: CallKind.video,
        outgoing: true,
        answered: true,
        elapsed: const Duration(seconds: 45),
        showVideoPlaceholder: true,
        onToggleMute: () {},
        onToggleSpeaker: () {},
        onToggleHold: () {},
        onEnd: () {},
        onMinimize: () {},
      ));
    case 'call/active_muted':
      return wrapScreenshot(CallStage(
        peerName: 'Анна',
        kind: CallKind.audio,
        outgoing: true,
        answered: true,
        elapsed: const Duration(seconds: 12),
        muted: true,
        onToggleMute: () {},
        onToggleSpeaker: () {},
        onToggleHold: () {},
        onEnd: () {},
        onMinimize: () {},
      ));
    case 'call/active_speaker':
      return wrapScreenshot(CallStage(
        peerName: 'Анна',
        kind: CallKind.audio,
        outgoing: true,
        answered: true,
        elapsed: const Duration(seconds: 30),
        speakerOn: true,
        onToggleMute: () {},
        onToggleSpeaker: () {},
        onToggleHold: () {},
        onEnd: () {},
        onMinimize: () {},
      ));
    case 'call/active_hold':
      return wrapScreenshot(CallStage(
        peerName: 'Анна',
        kind: CallKind.audio,
        outgoing: true,
        answered: true,
        elapsed: const Duration(minutes: 2),
        onHold: true,
        onToggleMute: () {},
        onToggleSpeaker: () {},
        onToggleHold: () {},
        onEnd: () {},
        onMinimize: () {},
      ));
    case 'call/waiting_network':
      return wrapScreenshot(CallStage(
        peerName: 'Анна',
        kind: CallKind.audio,
        outgoing: true,
        answered: true,
        elapsed: const Duration(seconds: 5),
        waitingForNetwork: true,
        onToggleMute: () {},
        onToggleSpeaker: () {},
        onToggleHold: () {},
        onEnd: () {},
        onMinimize: () {},
      ));
    case 'call/minimized':
      return wrapScreenshot(_MinimizedCallBar(peerName: 'Анна', status: '01:23'));
    case 'call/ended':
      return wrapScreenshot(const CallEndedOverlay(peerName: 'Анна'));

    // —— Calls history ——
    case 'calls/empty_all':
      return wrapScreenshot(_staticEmpty(
        icon: Icons.call_outlined,
        title: 'История звонков пуста',
        subtitle: 'Звонки появятся после аудио- или видеовызова',
      ));
    case 'calls/empty_missed':
      return wrapScreenshot(_staticEmpty(
        icon: Icons.phone_missed_outlined,
        title: 'Нет пропущенных звонков',
      ));
    case 'calls/row_completed_out':
      return wrapScreenshot(_CallsHistoryScaffold(rows: [
        _CallHistoryRow(name: 'Анна', subtitle: 'Исходящий · 1:20', icon: Icons.call_made, color: Colors.green),
      ]));
    case 'calls/row_missed_in':
      return wrapScreenshot(_CallsHistoryScaffold(rows: [
        _CallHistoryRow(name: 'Борис', subtitle: 'Пропущенный', icon: Icons.call_missed, color: Colors.red),
      ]));
    case 'calls/row_cancelled_out':
      return wrapScreenshot(_CallsHistoryScaffold(rows: [
        _CallHistoryRow(name: 'Анна', subtitle: 'Отменён', icon: Icons.call_end, color: Colors.orange),
      ]));
    case 'calls/row_rejected_in':
      return wrapScreenshot(_CallsHistoryScaffold(rows: [
        _CallHistoryRow(name: 'Кира', subtitle: 'Отклонён', icon: Icons.call_received, color: Colors.redAccent),
      ]));
    case 'calls/row_busy':
      return wrapScreenshot(_CallsHistoryScaffold(rows: [
        _CallHistoryRow(name: 'Даша', subtitle: 'Занято', icon: Icons.phone_disabled, color: Colors.amber),
      ]));
    case 'calls/row_failed':
      return wrapScreenshot(_CallsHistoryScaffold(rows: [
        _CallHistoryRow(name: 'Илья', subtitle: 'Ошибка соединения', icon: Icons.error_outline, color: Colors.red),
      ]));
    case 'calls/row_video_out':
      return wrapScreenshot(_CallsHistoryScaffold(rows: [
        _CallHistoryRow(name: 'Анна', subtitle: 'Видео · исходящий · 0:45', icon: Icons.videocam, color: Colors.green),
      ]));

    // —— Lists ——
    case 'conv_list/empty':
      return wrapScreenshot(_staticEmpty(
        icon: Icons.chat_bubble_outline,
        title: 'Нет чатов',
        subtitle: 'Начните новый разговор',
        actionLabel: 'Новый чат',
      ));
    case 'conv_list/populated':
      return wrapScreenshot(ListView(
        children: const [
          ChatListTile(title: 'Анна', subtitle: 'Черновик: привет…', timeLabel: '12:01', unreadCount: 0, isMuted: false),
          ChatListTile(title: 'Работа', subtitle: 'Совещание в 15:00', timeLabel: '11:40', unreadCount: 3, isGroup: true, isPinned: true),
          ChatListTile(title: 'Борис', subtitle: 'Ок', timeLabel: 'вчера', unreadCount: 1, isMuted: true, isOnline: true),
          ChatListTile(title: 'Сервис', subtitle: 'Недоступен', timeLabel: 'пн', unreachable: true),
        ],
      ));
    case 'conv_list/search_empty':
      return wrapScreenshot(_staticEmpty(
        icon: Icons.search_off,
        title: 'Ничего не найдено',
        subtitle: 'Попробуйте другой запрос',
      ));
    case 'contacts/empty':
      return wrapScreenshot(_staticEmpty(
        icon: Icons.people_outline,
        title: 'Нет контактов',
        subtitle: 'Добавьте человека по username или QR',
      ));
    case 'contacts/list':
      return wrapScreenshot(ListView(
        children: const [
          ListTile(leading: CircleAvatar(child: Text('А')), title: Text('Анна'), subtitle: Text('@anna')),
          ListTile(leading: CircleAvatar(child: Text('Б')), title: Text('Борис'), subtitle: Text('доверенный')),
          ListTile(leading: CircleAvatar(child: Text('К')), title: Text('Кира'), subtitle: Text('в сети')),
        ],
      ));

    // —— Devices ——
    case 'devices/loading':
      return wrapScreenshot(const Center(child: Icon(Icons.hourglass_top, size: 40, color: Colors.white54)));
    case 'devices/error':
      return wrapScreenshot(_staticEmpty(
        icon: Icons.error_outline,
        title: 'Не удалось загрузить устройства',
        subtitle: 'Проверьте соединение и повторите',
        actionLabel: 'Повторить',
      ));
    case 'devices/empty':
      return wrapScreenshot(_staticEmpty(
        icon: Icons.devices_other,
        title: 'Нет устройств',
      ));
    case 'devices/list':
      return wrapScreenshot(ListView(
        children: const [
          ListTile(leading: Icon(Icons.laptop_mac), title: Text('MacBook'), subtitle: Text('Это устройство · сейчас')),
          ListTile(leading: Icon(Icons.phone_iphone), title: Text('iPhone'), subtitle: Text('2 часа назад')),
        ],
      ));

    // —— Auth ——
    case 'auth/onboarding_idle':
      return wrapScreenshot(_AuthCard(
        title: 'Создать аккаунт',
        fields: const ['Имя', 'Телефон', 'Пароль'],
        primary: 'Зарегистрироваться',
        secondary: 'Уже есть аккаунт',
      ));
    case 'auth/login_idle':
      return wrapScreenshot(_AuthCard(
        title: 'Вход',
        fields: const ['Телефон / email / login', 'Пароль'],
        primary: 'Войти',
      ));
    case 'auth/login_loading':
      return wrapScreenshot(_AuthCard(
        title: 'Вход',
        fields: const ['Телефон / email / login', 'Пароль'],
        primary: 'Войти',
        loading: true,
      ));
    case 'auth/login_error':
      return wrapScreenshot(_AuthCard(
        title: 'Вход',
        fields: const ['Телефон / email / login', 'Пароль'],
        primary: 'Войти',
        error: 'Неверный пароль',
      ));
    case 'auth/app_lock_pin':
      return wrapScreenshot(_PinPad(title: 'Введите PIN', error: null));
    case 'auth/app_lock_wrong':
      return wrapScreenshot(_PinPad(title: 'Введите PIN', error: 'Неверный PIN'));
    case 'auth/pin_setup_enter':
      return wrapScreenshot(_PinPad(title: 'Придумайте PIN', error: null));

    // —— Settings / misc ——
    case 'settings/hub':
      return wrapScreenshot(ListView(
        children: const [
          ListTile(leading: Icon(Icons.person_outline), title: Text('Профиль'), subtitle: Text('Имя, username, QR')),
          ListTile(leading: Icon(Icons.shield_outlined), title: Text('Приватность и защита')),
          ListTile(leading: Icon(Icons.notifications_outlined), title: Text('Уведомления')),
          ListTile(leading: Icon(Icons.palette_outlined), title: Text('Оформление')),
          ListTile(leading: Icon(Icons.devices), title: Text('Устройства')),
          ListTile(leading: Icon(Icons.storage_outlined), title: Text('Данные и хранение')),
        ],
      ));
    case 'settings/appearance':
      return wrapScreenshot(ListView(
        children: const [
          ListTile(title: Text('Тема'), subtitle: Text('Системная')),
          ListTile(title: Text('Размер текста'), subtitle: Text('Обычный')),
          SwitchListTile(title: Text('Компактный режим'), value: false, onChanged: null),
          SwitchListTile(title: Text('Уменьшить движение'), value: false, onChanged: null),
        ],
      ));
    case 'settings/notifications':
      return wrapScreenshot(ListView(
        children: const [
          SwitchListTile(title: Text('Уведомления'), value: true, onChanged: null),
          ListTile(title: Text('Превью'), subtitle: Text('Имя и текст')),
          SwitchListTile(title: Text('Не беспокоить'), value: false, onChanged: null),
        ],
      ));
    case 'profile/home':
      return wrapScreenshot(ListView(
        children: const [
          SizedBox(height: 24),
          CircleAvatar(radius: 40, child: Text('Я')),
          ListTile(title: Text('Отображаемое имя'), subtitle: Text('Вы')),
          ListTile(title: Text('Username'), subtitle: Text('@you')),
          ListTile(title: Text('Публичный ID'), subtitle: Text('abc123…')),
        ],
      ));
    case 'storage/home':
      return wrapScreenshot(ListView(
        children: const [
          ListTile(title: Text('Сообщения'), subtitle: Text('Локально + нода')),
          ListTile(title: Text('Медиа'), subtitle: Text('Кэш · 120 МБ')),
          ListTile(title: Text('Последняя синхронизация'), subtitle: Text('только что')),
          ListTile(title: Text('Очистить кэш')),
        ],
      ));
    case 'hidden/empty':
      return wrapScreenshot(_staticEmpty(
        icon: Icons.visibility_off_outlined,
        title: 'Нет скрытых чатов',
        subtitle: 'Скрытые диалоги появятся здесь',
      ));
    case 'security/emergency_lock':
      return wrapScreenshot(ListView(
        children: const [
          ListTile(title: Text('Мягкая'), subtitle: Text('Блокировка приложения')),
          ListTile(title: Text('Полная'), subtitle: Text('Выход на всех устройствах')),
          ListTile(title: Text('Критическая'), subtitle: Text('Стирание локальных данных')),
        ],
      ));

    default:
      return wrapScreenshot(Center(child: Text('Missing scene: ${state.group}/${state.id}')));
  }
}


Widget _staticEmpty({
  required IconData icon,
  required String title,
  String? subtitle,
  String? actionLabel,
}) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: Colors.white38),
          const SizedBox(height: 16),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54)),
          ],
          if (actionLabel != null) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: () {}, child: Text(actionLabel)),
          ],
        ],
      ),
    ),
  );
}

Widget _bubbleShot({
  required ChatMessage message,
  MessageDeliveryStatus? status,
  String? deliveryError,
  bool pinned = false,
  bool highlighted = false,
}) {
  final mine = message.senderUserId == 'me';
  return wrapScreenshot(
    _ChatFrame(
      body: _bubblePane([
        ChatMessageBubble(
          message: message,
          isMine: mine,
          layout: _solo(message),
          deliveryStatus: status,
          deliveryError: deliveryError,
          isPinned: pinned,
          highlighted: highlighted,
        ),
      ]),
    ),
  );
}

Widget _bubblePane(List<Widget> children) {
  return ListView(
    padding: const EdgeInsets.all(12),
    children: children,
  );
}

Widget _fakeComposer() {
  return Container(
    padding: const EdgeInsets.all(8),
    color: AppColors.surfaceDark,
    child: Row(
      children: [
        const Icon(Icons.add, color: Colors.white54),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            height: 36,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Text('Сообщение', style: TextStyle(color: Colors.white38)),
          ),
        ),
        const SizedBox(width: 8),
        const Icon(Icons.send, color: AppColors.accentBlue),
      ],
    ),
  );
}

class _ChatFrame extends StatelessWidget {
  const _ChatFrame({required this.body, this.banner});
  final Widget body;
  final Widget? banner;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AppBar(
          title: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Анна', style: TextStyle(fontSize: 16)),
              Text('в сети', style: TextStyle(fontSize: 12, color: Colors.white70)),
            ],
          ),
          actions: const [
            Icon(Icons.call_outlined),
            SizedBox(width: 12),
            Icon(Icons.videocam_outlined),
            SizedBox(width: 12),
          ],
        ),
        if (banner != null) banner!,
        Expanded(child: body),
        _fakeComposer(),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.color, required this.text});
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.2),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(text, style: AppTypography.caption.copyWith(color: color)),
    );
  }
}

class _MinimizedCallBar extends StatelessWidget {
  const _MinimizedCallBar({required this.peerName, required this.status});
  final String peerName;
  final String status;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceDark,
          borderRadius: BorderRadius.circular(AppRadii.medium),
        ),
        child: Row(
          children: [
            const Icon(Icons.call, color: AppColors.successGreen),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(peerName, style: AppTypography.title.copyWith(color: AppColors.textInverse)),
                  Text(status, style: AppTypography.caption.copyWith(color: AppColors.textMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CallsHistoryScaffold extends StatelessWidget {
  const _CallsHistoryScaffold({required this.rows});
  final List<_CallHistoryRow> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AppBar(title: const Text('Звонки')),
        Expanded(child: ListView(children: rows)),
      ],
    );
  }
}

class _CallHistoryRow extends StatelessWidget {
  const _CallHistoryRow({
    required this.name,
    required this.subtitle,
    required this.icon,
    required this.color,
  });
  final String name;
  final String subtitle;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(child: Text(name.characters.first)),
      title: Text(name),
      subtitle: Text(subtitle),
      trailing: Icon(icon, color: color),
    );
  }
}

class _AuthCard extends StatelessWidget {
  const _AuthCard({
    required this.title,
    required this.fields,
    required this.primary,
    this.secondary,
    this.loading = false,
    this.error,
  });

  final String title;
  final List<String> fields;
  final String primary;
  final String? secondary;
  final bool loading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 48),
          Text(title, style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 24),
          for (final f in fields) ...[
            TextField(decoration: InputDecoration(labelText: f)),
            const SizedBox(height: 12),
          ],
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.redAccent)),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: loading ? null : () {},
            child: loading
                ? const Text('…')
                : Text(primary),
          ),
          if (secondary != null)
            TextButton(onPressed: () {}, child: Text(secondary!)),
        ],
      ),
    );
  }
}

class _PinPad extends StatelessWidget {
  const _PinPad({required this.title, this.error});
  final String title;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.circle, size: 14),
              SizedBox(width: 10),
              Icon(Icons.circle, size: 14),
              SizedBox(width: 10),
              Icon(Icons.circle_outlined, size: 14),
              SizedBox(width: 10),
              Icon(Icons.circle_outlined, size: 14),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              for (final d in ['1', '2', '3', '4', '5', '6', '7', '8', '9', '', '0', '⌫'])
                SizedBox(
                  width: 64,
                  height: 64,
                  child: d.isEmpty
                      ? const SizedBox.shrink()
                      : OutlinedButton(onPressed: () {}, child: Text(d, style: const TextStyle(fontSize: 20))),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
