import 'package:flutter/services.dart';

String normalizePhoneNumber(String raw) {
  var digits = raw.replaceAll(RegExp(r'\D'), '');
  if (digits.length == 10) digits = '7$digits';
  if (digits.length == 11 && digits.startsWith('8')) {
    digits = '7${digits.substring(1)}';
  }
  return digits.isEmpty ? '' : '+$digits';
}

String formatPhoneNumber(String raw) {
  final normalized = normalizePhoneNumber(raw);
  if (!normalized.startsWith('+7') || normalized.length > 12) {
    return normalized;
  }
  final digits = normalized.substring(2);
  final out = StringBuffer('+7');
  if (digits.isNotEmpty) {
    out.write(
      ' (${digits.substring(0, digits.length < 3 ? digits.length : 3)}',
    );
  }
  if (digits.length >= 3) out.write(')');
  if (digits.length > 3) {
    out.write(' ${digits.substring(3, digits.length < 6 ? digits.length : 6)}');
  }
  if (digits.length > 6) {
    out.write('-${digits.substring(6, digits.length < 8 ? digits.length : 8)}');
  }
  if (digits.length > 8) {
    out.write(
      '-${digits.substring(8, digits.length < 10 ? digits.length : 10)}',
    );
  }
  return out.toString();
}

class PhoneNumberInputFormatter extends TextInputFormatter {
  const PhoneNumberInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final formatted = formatPhoneNumber(newValue.text);
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

bool isValidEmailAddress(String value) {
  if (value.isEmpty || value.length > 254 || value.contains('..')) return false;
  return RegExp(
    r'^[A-Za-z0-9.!#$%&\x27*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$',
  ).hasMatch(value);
}
