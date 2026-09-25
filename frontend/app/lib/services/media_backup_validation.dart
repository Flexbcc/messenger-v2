import 'dart:convert';
import 'dart:typed_data';

import '../models/attachment_pointer.dart';

const int maxMediaBackupEntries = 10000;
const int maxMediaBackupItemBytes = maxAttachmentCiphertextBytes;
// The enclosing backup file is capped at 256 MiB; decoded Base64 media must
// remain below its theoretical 3/4 expansion boundary as well.
const int maxMediaBackupTotalBytes = 192 * 1024 * 1024;

final RegExp _mediaIdPattern = RegExp(r'^[a-f0-9]{64}$');

void validateMediaStorageUser(String userId) {
  if (userId.isEmpty ||
      userId.length > 128 ||
      !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(userId)) {
    throw const FormatException('invalid media cache user id');
  }
}

void validateMediaStorageInput(
  String userId,
  String mediaId, {
  Uint8List? bytes,
}) {
  validateMediaStorageUser(userId);
  if (!_mediaIdPattern.hasMatch(mediaId)) {
    throw const FormatException('invalid media id');
  }
  if (bytes != null &&
      (bytes.isEmpty || bytes.length > maxMediaBackupItemBytes)) {
    throw const FormatException('invalid media ciphertext size');
  }
}

/// Validates and decodes a ciphertext-media section before it reaches storage.
List<({String mediaId, Uint8List bytes})> decodeMediaBackup(
  Map<String, dynamic> values,
) {
  if (values.length > maxMediaBackupEntries) {
    throw const FormatException('too many media backup entries');
  }

  var totalBytes = 0;
  final decoded = <({String mediaId, Uint8List bytes})>[];
  for (final entry in values.entries) {
    if (!_mediaIdPattern.hasMatch(entry.key) || entry.value is! String) {
      throw const FormatException('invalid media backup entry');
    }
    final encoded = entry.value as String;
    // A Base64 payload cannot decode to more than 3/4 of its encoded size.
    if (encoded.length > ((maxMediaBackupItemBytes + 2) ~/ 3) * 4) {
      throw const FormatException('media backup entry is too large');
    }

    late final Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      throw const FormatException('invalid media backup encoding');
    }
    if (bytes.length > maxMediaBackupItemBytes) {
      throw const FormatException('media backup entry is too large');
    }
    validateMediaStorageInput('backup', entry.key, bytes: bytes);
    totalBytes += bytes.length;
    if (totalBytes > maxMediaBackupTotalBytes) {
      throw const FormatException('media backup is too large');
    }
    decoded.add((mediaId: entry.key, bytes: bytes));
  }
  return decoded;
}
