String requiredBoundedString(
  Map<String, dynamic> json,
  String key, {
  required int maxLength,
}) {
  final value = json[key];
  if (value is! String || value.isEmpty || value.length > maxLength) {
    throw FormatException('invalid $key');
  }
  return value;
}

String? optionalBoundedString(
  Map<String, dynamic> json,
  String key, {
  required int maxLength,
}) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.isEmpty || value.length > maxLength) {
    throw FormatException('invalid $key');
  }
  return value;
}

DateTime requiredDateTime(Map<String, dynamic> json, String key) {
  final raw = requiredBoundedString(json, key, maxLength: 64);
  final value = DateTime.tryParse(raw);
  if (value == null || value.year < 2000 || value.year > 2200) {
    throw FormatException('invalid $key');
  }
  return value;
}

List<String> requiredBoundedStringList(
  Map<String, dynamic> json,
  String key, {
  required int maxItems,
  required int maxItemLength,
}) {
  final raw = json[key];
  if (raw is! List || raw.length > maxItems) {
    throw FormatException('invalid $key');
  }
  final result = <String>[];
  for (final item in raw) {
    if (item is! String || item.isEmpty || item.length > maxItemLength) {
      throw FormatException('invalid $key');
    }
    result.add(item);
  }
  return List.unmodifiable(result);
}
