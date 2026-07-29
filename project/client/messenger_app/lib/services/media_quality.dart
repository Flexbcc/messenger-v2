import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'settings_runtime.dart';

/// Compresses outbound images according to [media.image_quality].
/// Video has no client encoder — [prepareVideo] only records the quality hint.
class MediaQuality {
  MediaQuality._();

  /// Returns possibly resized PNG bytes, or the original when quality is
  /// `original` / already small enough.
  static Future<Uint8List> prepareImage(Uint8List bytes) async {
    final quality = await SettingsRuntime.instance.imageQuality();
    if (quality == 'original') return bytes;

    final maxEdge = quality == 'compressed' ? 1280 : 1920;
    return _resizeIfNeeded(bytes, maxEdge: maxEdge);
  }

  /// No recompression pipeline — returns [bytes] unchanged and the catalog hint.
  static Future<(Uint8List bytes, String qualityHint)> prepareVideo(Uint8List bytes) async {
    final quality = await SettingsRuntime.instance.videoQuality();
    // Without a video encoder we only skip recompression (always pass-through).
    return (bytes, quality);
  }

  static Future<Uint8List> _resizeIfNeeded(Uint8List bytes, {required int maxEdge}) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final w = image.width;
      final h = image.height;
      final longest = math.max(w, h);
      if (longest <= maxEdge) {
        image.dispose();
        return bytes;
      }
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
      final data = await resizedFrame.image.toByteData(format: ui.ImageByteFormat.png);
      resizedFrame.image.dispose();
      if (data == null) return bytes;
      return data.buffer.asUint8List();
    } catch (_) {
      return bytes;
    }
  }
}
