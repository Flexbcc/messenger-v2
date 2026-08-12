import '../services/api_client.dart';

String friendlyApiError(Object error) {
  if (error is StateError) return error.message;
  if (error is ArgumentError) {
    final msg = error.message?.toString() ?? error.toString();
    return msg.replaceFirst(RegExp(r'^Invalid argument\(s\):\s*'), '');
  }
  if (error is ApiException) {
    if (error.statusCode == 404 && error.message.contains('Unknown user_id')) {
      return 'Пользователь не найден. Проверьте User ID: он должен быть скопирован '
          'из Настройки → Аккаунт у собеседника (UUID, не имя).';
    }
    if (error.statusCode == 404 &&
        error.message.contains('Unknown user_id on remote node')) {
      return 'Пользователь не найден на удалённой ноде. Для теста используйте двух пользователей, '
          'зарегистрированных на одном Home Node (localhost).';
    }
    return error.message;
  }
  final text = error.toString();
  if (text.contains('Unknown user_id')) {
    return 'Пользователь не найден. Убедитесь, что собеседник зарегистрирован '
        'и вы вставили его User ID из Настройки → Аккаунт.';
  }
  return text;
}
