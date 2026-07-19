import '../models/message.dart';
import '../state/app_controller.dart';

String messageDisplayBody(ChatMessage message) {
  if (message.decryptFailed) return 'Зашифрованное сообщение';
  return switch (message.contentType) {
    'image' => 'Фото',
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

  final hm = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (messageDay == today) return hm;
  if (messageDay == today.subtract(const Duration(days: 1))) return 'Вчера, $hm';
  if (now.difference(local).inDays < 7) {
    const weekdays = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
    return '${weekdays[local.weekday - 1]}, $hm';
  }
  return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.$local.year';
}

String formatDateSeparator(DateTime time) {
  final local = time.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final messageDay = DateTime(local.year, local.month, local.day);

  if (messageDay == today) return 'Сегодня';
  if (messageDay == today.subtract(const Duration(days: 1))) return 'Вчера';
  const months = [
    'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
    'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
  ];
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}

bool isSameDay(DateTime a, DateTime b) {
  final la = a.toLocal();
  final lb = b.toLocal();
  return la.year == lb.year && la.month == lb.month && la.day == lb.day;
}
