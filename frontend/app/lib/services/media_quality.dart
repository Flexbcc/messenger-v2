import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'settings_runtime.dart';

/// Prepares outbound images before encryption. Re-encoding also removes EXIF,
/// GPS and camera metadata when [media.strip_image_metadata] is enabled.
/// Video has no bundled client encoder yet and is passed through unchanged.
class MediaQuality {
  MediaQuality._();

  /// Returns possibly resized PNG bytes, or the original when quality is
  /// `original` / already small enough.
  static Future<Uint8List> prepareImage(Uint8List bytes) async {
    final quality = await SettingsRuntime.instance.imageQuality();
    final stripMetadata = await SettingsRuntime.instance.stripImageMetadata();
    if (quality == 'original' && !stripMetadata) return bytes;

    final maxEdge = quality == 'original'
        ? null
        : quality == 'compressed'
        ? 1280
        : 1920;
    return _reencodeImage(
      bytes,
      maxEdge: maxEdge,
      forceReencode: stripMetadata,
    );
  }

  static Future<Uint8List> _reencodeImage(
    Uint8List bytes, {
    required int? maxEdge,
    required bool forceReencode,
  }) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final w = image.width;
      final h = image.height;
      final longest = math.max(w, h);
      if (maxEdge != null && longest > maxEdge) {
        final scale = maxEdge / longest;
        final tw = math.max(1, (w * scale).round());
        final th = math.max(1, (h * scale).round());
        image.dispose();
        final resizedCodec = await ui.instantiateImageCodec(
          bytes,
          targetWidth: tw,
          targetHeight: th,
        );
        final resizedFrame = await resizedCodec.getNextFrame();
        final data = await resizedFrame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        resizedFrame.image.dispose();
        if (data == null) return bytes;
        return data.buffer.asUint8List();
      }
      if (!forceReencode) {
        image.dispose();
        return bytes;
      }
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return bytes;
      return data.buffer.asUint8List();
    } catch (_) {
      return bytes;
    }
  }
}
