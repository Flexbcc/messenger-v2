import 'settings_runtime.dart';

/// Cached catalog date/time prefs for sync [formatMessageTime] call sites.
class MessageFormatPrefs {
  MessageFormatPrefs._();

  static String timeFormat = '24h';
  static String dateFormat = 'DD.MM.YYYY';
  static String language = 'ru';

  static Future<void> reload() async {
    final runtime = SettingsRuntime.instance;
    timeFormat = await runtime.timeFormat();
    dateFormat = await runtime.dateFormat();
    language = await runtime.language();
  }

  static String formatClock(DateTime local) {
    final minute = local.minute.toString().padLeft(2, '0');
    if (timeFormat == '12h') {
      final hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
      final suffix = local.hour >= 12 ? 'PM' : 'AM';
      return '$hour12:$minute $suffix';
    }
    return '${local.hour.toString().padLeft(2, '0')}:$minute';
  }

  static String formatDate(DateTime local) {
    final d = local.day.toString().padLeft(2, '0');
    final m = local.month.toString().padLeft(2, '0');
    final y = local.year.toString();
    return switch (dateFormat) {
      'YYYY-MM-DD' => '$y-$m-$d',
      'MM/DD/YYYY' => '$m/$d/$y',
      _ => '$d.$m.$y',
    };
  }
}
