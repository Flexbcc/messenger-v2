import '../models/message.dart';
import '../services/message_format_prefs.dart';
import '../state/app_controller.dart';

String messageDisplayBody(ChatMessage message) {
  if (message.decryptFailed) return 'Зашифрованное сообщение';
  return switch (message.contentType) {
    'image' => 'Фото',
    'file' => 'Файл',
    'video' => 'Видео',
    'text' => message.plaintext ?? '…',
    _ => 'Сообщение',
  };
}

String messagePreview(ChatMessage message) => messageDisplayBody(message);

String formatListPreview({
  required ChatMessage message,
  required AppController controller,
  required String previewMode,
}) {
  final sender = message.senderUserId == controller.session?.userId
      ? 'Вы'
      : controller.labelFor(message.senderUserId);

  return switch (previewMode) {
    'Скрыто' => 'Новое сообщение',
    'Только приложение' => 'Messenger',
    'Только имя отправителя' => sender,
    _ => messagePreview(message),
  };
}

String formatMessageTime(DateTime time) {
  final local = time.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final messageDay = DateTime(local.year, local.month, local.day);

  final hm = MessageFormatPrefs.formatClock(local);
  final en = MessageFormatPrefs.language == 'en';
  if (messageDay == today) return hm;
  if (messageDay == today.subtract(const Duration(days: 1))) {
    return en ? 'Yesterday, $hm' : 'Вчера, $hm';
  }
  if (now.difference(local).inDays < 7) {
    const weekdaysRu = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
    const weekdaysEn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final weekdays = en ? weekdaysEn : weekdaysRu;
    return '${weekdays[local.weekday - 1]}, $hm';
  }
  return '${MessageFormatPrefs.formatDate(local)}, $hm';
}

String formatDateSeparator(DateTime time) {
  final local = time.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final messageDay = DateTime(local.year, local.month, local.day);
  final en = MessageFormatPrefs.language == 'en';

  if (messageDay == today) return en ? 'Today' : 'Сегодня';
  if (messageDay == today.subtract(const Duration(days: 1))) {
    return en ? 'Yesterday' : 'Вчера';
  }
  if (en) return MessageFormatPrefs.formatDate(local);
  const months = [
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}

bool isSameDay(DateTime a, DateTime b) {
  final la = a.toLocal();
  final lb = b.toLocal();
  return la.year == lb.year && la.month == lb.month && la.day == lb.day;
}
