import 'dart:convert';
import 'dart:typed_data';

Uint8List decodeBase64Exact(
  Object? value, {
  required int expectedBytes,
  required String field,
  bool urlSafe = false,
  int maxEncodedCharacters = 256,
}) {
  final decoded = decodeBase64Bounded(
    value,
    minimumBytes: expectedBytes,
    maximumBytes: expectedBytes,
    field: field,
    urlSafe: urlSafe,
    maxEncodedCharacters: maxEncodedCharacters,
  );
  return decoded;
}

Uint8List decodeBase64Bounded(
  Object? value, {
  required int minimumBytes,
  required int maximumBytes,
  required String field,
  bool urlSafe = false,
  int maxEncodedCharacters = 256,
}) {
  if (minimumBytes < 0 || maximumBytes < minimumBytes) {
    throw ArgumentError('Invalid decoded byte bounds');
  }
  if (value is! String ||
      value.isEmpty ||
      value.length > maxEncodedCharacters) {
    throw FormatException('$field is invalid');
  }
  final pattern = urlSafe
      ? RegExp(r'^[A-Za-z0-9_-]+={0,2}$')
      : RegExp(r'^[A-Za-z0-9+/]+={0,2}$');
  if (!pattern.hasMatch(value)) throw FormatException('$field is invalid');
  try {
    final decoded = (urlSafe ? base64Url : base64).decode(value);
    if (decoded.length < minimumBytes || decoded.length > maximumBytes) {
      throw FormatException('$field has an invalid length');
    }
    return decoded;
  } on FormatException {
    throw FormatException('$field is invalid');
  }
}
