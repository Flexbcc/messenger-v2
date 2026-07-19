// Форматирование для UI.
library;

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatTimestamp(int unixSec) {
  final dt = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000);
  return '${dt.day.toString().padLeft(2, '0')}.'
      '${dt.month.toString().padLeft(2, '0')}.'
      '${dt.year} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';
}

String peerFingerprint(String pubkey) {
  final parts = pubkey.split(':');
  if (parts.length < 2) return pubkey;
  final b64 = parts[1];
  if (b64.length >= 11) return '${b64.substring(0, 11)}…';
  return b64;
}
