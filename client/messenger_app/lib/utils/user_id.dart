/// User IDs are UUIDs issued by Home Node on registration.
final _uuidRe = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

String normalizeUserId(String raw) => raw.trim();

bool isValidUserIdFormat(String id) => _uuidRe.hasMatch(id);

String userIdFormatHint() =>
    'Нужен полный User ID (формат xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx), '
    'не имя и не телефон. Скопируйте из Настройки → Аккаунт.';
