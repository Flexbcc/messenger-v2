import 'dart:convert';

import 'message.dart';

const maxAttachmentPlaintextBytes = 64 * 1024 * 1024;
const attachmentEncryptionOverheadBytes = 12 + 16;
const maxAttachmentCiphertextBytes =
    maxAttachmentPlaintextBytes + attachmentEncryptionOverheadBytes;

/// Bounded presentation metadata from an E2EE attachment pointer.
class AttachmentPointerMetadata {
  const AttachmentPointerMetadata({this.filename, this.mime, this.size});

  const AttachmentPointerMetadata.invalid()
    : filename = null,
      mime = null,
      size = maxAttachmentPlaintextBytes + 1;

  final String? filename;
  final String? mime;

  /// Invalid declarations use an over-limit value so autodownload fails
  /// closed. `null` is reserved for legacy pointers without a size field.
  final int? size;

  static AttachmentPointerMetadata? fromMessage(ChatMessage message) {
    final raw = message.plaintext?.trim();
    if (raw == null || !raw.startsWith('{')) {
      return const AttachmentPointerMetadata.invalid();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const AttachmentPointerMetadata.invalid();
      }
      if (decoded['pending'] == true) return null;
      final filenameRaw = decoded['filename'];
      final mimeRaw = decoded['mime'];
      final sizeRaw = decoded['size'];
      final filename =
          filenameRaw is String &&
              filenameRaw.isNotEmpty &&
              filenameRaw.length <= 255
          ? filenameRaw
          : null;
      final mime =
          mimeRaw is String && mimeRaw.isNotEmpty && mimeRaw.length <= 255
          ? mimeRaw
          : null;
      final int? size;
      if (sizeRaw == null) {
        size = null;
      } else if (sizeRaw is int &&
          sizeRaw > 0 &&
          sizeRaw <= maxAttachmentPlaintextBytes) {
        size = sizeRaw;
      } else {
        size = maxAttachmentPlaintextBytes + 1;
      }
      return AttachmentPointerMetadata(
        filename: filename,
        mime: mime,
        size: size,
      );
    } catch (_) {
      return const AttachmentPointerMetadata.invalid();
    }
  }
}
