import 'dart:typed_data';

import '../models/attachment_pointer.dart';

const maxOpenedAttachmentBytes = maxAttachmentPlaintextBytes;

final RegExp _safeMimePattern = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}$',
);

({String filename, String mime}) validateAttachmentForOpen(
  Uint8List bytes,
  String filename,
  String mime,
) {
  if (bytes.isEmpty || bytes.length > maxOpenedAttachmentBytes) {
    throw ArgumentError('attachment size is invalid');
  }

  var normalizedName = filename.trim().replaceAll(
    RegExp(r'[^A-Za-z0-9_.-]'),
    '_',
  );
  normalizedName = normalizedName.replaceFirst(RegExp(r'^\.+'), '');
  if (normalizedName.length > 120) {
    normalizedName = normalizedName.substring(0, 120);
  }
  if (normalizedName.isEmpty) normalizedName = 'attachment';

  final normalizedMime = mime.trim();
  return (
    filename: normalizedName,
    mime:
        normalizedMime.length <= 255 &&
            _safeMimePattern.hasMatch(normalizedMime)
        ? normalizedMime.toLowerCase()
        : 'application/octet-stream',
  );
}
