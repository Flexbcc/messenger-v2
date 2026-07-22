import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';

/// Dev helper: capture the current UI (viewport or full scrollable page).
class DevScreenCapture {
  DevScreenCapture._();

  static const _pixelRatio = 2.0;

  /// Below this scroll extent we treat the page as "fits on one screen".
  static const _minScrollForStitch = 24.0;

  static Future<Directory> outputDirectory() async {
    final candidates = <Future<Directory?> Function()>[
      () async {
        try {
          final downloads = await getDownloadsDirectory();
          if (downloads == null) return null;
          return Directory('${downloads.path}/MessengerScreens');
        } catch (_) {
          return null;
        }
      },
      () async {
        final support = await getApplicationSupportDirectory();
        return Directory('${support.path}/MessengerScreens');
      },
      () async {
        final docs = await getApplicationDocumentsDirectory();
        return Directory('${docs.path}/MessengerScreens');
      },
    ];

    Object? lastError;
    for (final build in candidates) {
      try {
        final dir = await build();
        if (dir == null) continue;
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
        final probe = File('${dir.path}/.write_probe');
        await probe.writeAsString('ok');
        await probe.delete();
        return dir;
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError('Нет доступа к папке для скриншотов: $lastError');
  }

  static Future<void> revealInFileManager(File file) async {
    if (kIsWeb) return;
    try {
      if (Platform.isMacOS) {
        await Process.run('open', ['-R', file.path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [file.parent.path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', file.path]);
      }
    } catch (e) {
      debugPrint('DevScreenCapture.reveal failed: $e');
    }
  }

  /// Capture [boundaryKey] as-is (current viewport, including chrome).
  static Future<File?> captureViewport(GlobalKey boundaryKey, {String? label}) async {
    final image = await _toImage(boundaryKey);
    if (image == null) return null;
    return _save(image, label: label ?? 'viewport');
  }

  /// Full-page capture of the **visible** vertical scroller.
  ///
  /// - No meaningful overflow → one shot (no stitch).
  /// - Real scroll → stitch by scroll deltas (excludes bottom nav).
  ///
  /// Ignores offstage [IndexedStack] tabs so we don't scroll Settings while
  /// looking at Chats.
  static Future<File?> captureFullScroll(
    GlobalKey boundaryKey, {
    String? label,
  }) async {
    final boundaryContext = boundaryKey.currentContext;
    if (boundaryContext == null) return null;

    final boundary = boundaryContext.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return captureViewport(boundaryKey, label: label);

    final scrollable = _findBestVerticalScrollable(boundaryContext);
    if (scrollable == null) {
      return captureViewport(boundaryKey, label: label ?? 'viewport');
    }

    final position = scrollable.position;
    if (!position.hasPixels || !position.hasContentDimensions) {
      return captureViewport(boundaryKey, label: label ?? 'viewport');
    }

    final scrollBox = scrollable.context.findRenderObject() as RenderBox?;
    if (scrollBox == null || !scrollBox.hasSize) {
      return captureViewport(boundaryKey, label: label ?? 'viewport');
    }

    final saved = position.pixels;
    final maxExtent = position.maxScrollExtent;
    final viewH = position.viewportDimension;
    if (viewH <= 1) {
      return captureViewport(boundaryKey, label: label ?? 'viewport');
    }

    // Fits on one screen — do not stitch.
    if (maxExtent < _minScrollForStitch) {
      return _captureScrollableOnce(
        boundaryKey: boundaryKey,
        boundary: boundary,
        scrollBox: scrollBox,
        label: label,
      );
    }

    final offsets = _scrollOffsets(maxExtent: maxExtent, viewH: viewH);
    if (offsets.length <= 1) {
      return _captureScrollableOnce(
        boundaryKey: boundaryKey,
        boundary: boundary,
        scrollBox: scrollBox,
        label: label,
      );
    }

    final slices = <ui.Image>[];
    final usedOffsets = <double>[];

    try {
      final scrollableContext = scrollable.context;
      var lastPixels = -1.0;
      for (final offset in offsets) {
        position.jumpTo(offset);
        await _settleFrames();

        final pixels = position.pixels;
        if (usedOffsets.isNotEmpty && (pixels - lastPixels).abs() < 0.5) {
          break;
        }
        lastPixels = pixels;

        if (!scrollableContext.mounted) break;
        final box = scrollableContext.findRenderObject() as RenderBox?;
        final b = boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
        if (box == null || b == null || !_isVisiblyPainting(box)) break;
        final region = _rectInBoundary(b, box);
        if (region == null || region.height < 8) break;

        final slice = await _captureRegion(boundaryKey, region);
        if (slice == null) break;
        slices.add(slice);
        usedOffsets.add(pixels);
      }
    } finally {
      position.jumpTo(saved.clamp(0.0, maxExtent));
      await WidgetsBinding.instance.endOfFrame;
    }

    if (slices.isEmpty) return null;
    if (slices.length == 1) {
      return _save(slices.first, label: label ?? 'full');
    }

    final stitched = await _stitchByScrollDeltas(
      slices: slices,
      offsets: usedOffsets,
      viewHLogical: viewH,
      pixelRatio: _pixelRatio,
    );
    for (final s in slices) {
      s.dispose();
    }
    return _save(stitched, label: label ?? 'full');
  }

  static Future<File?> _captureScrollableOnce({
    required GlobalKey boundaryKey,
    required RenderRepaintBoundary boundary,
    required RenderBox scrollBox,
    String? label,
  }) async {
    final region = _rectInBoundary(boundary, scrollBox);
    if (region == null) return captureViewport(boundaryKey, label: label);
    final one = await _captureRegion(boundaryKey, region);
    if (one == null) return null;
    return _save(one, label: label ?? 'full');
  }

  static List<double> _scrollOffsets({required double maxExtent, required double viewH}) {
    final offsets = <double>[0.0];
    var o = 0.0;
    while (o < maxExtent - 0.5) {
      o = math.min(o + viewH, maxExtent);
      if ((o - offsets.last).abs() > 0.5) {
        offsets.add(o);
      } else {
        break;
      }
    }
    return offsets;
  }

  static Future<void> _settleFrames() async {
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 48));
    await WidgetsBinding.instance.endOfFrame;
  }

  /// Prefer the visibly painted scroller with the largest extent.
  static ScrollableState? _findBestVerticalScrollable(BuildContext root) {
    ScrollableState? best;
    var bestExtent = -1.0;
    var bestView = -1.0;

    void visit(Element element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        final state = element.state as ScrollableState;
        final pos = state.position;
        final box = state.context.findRenderObject();
        if (box is RenderBox &&
            box.hasSize &&
            _isVisiblyPainting(box) &&
            pos.axis == Axis.vertical &&
            pos.hasContentDimensions) {
          final extent = pos.maxScrollExtent;
          final view = pos.viewportDimension;
          final better = extent > bestExtent + 0.5 ||
              ((extent - bestExtent).abs() <= 0.5 && view > bestView);
          if (better) {
            bestExtent = extent;
            bestView = view;
            best = state;
          }
        }
      }
      element.visitChildren(visit);
    }

    root.visitChildElements(visit);
    return best;
  }

  /// False for Offstage / zero-opacity ancestors (hidden IndexedStack children).
  static bool _isVisiblyPainting(RenderObject object) {
    RenderObject? node = object;
    while (node != null) {
      if (node is RenderOffstage && node.offstage) return false;
      if (node is RenderOpacity && node.opacity < 0.05) return false;
      node = node.parent;
    }
    return object.attached;
  }

  static Rect? _rectInBoundary(RenderRepaintBoundary boundary, RenderBox target) {
    try {
      final topLeft = target.localToGlobal(Offset.zero, ancestor: boundary);
      final rect = topLeft & target.size;
      final bounds = Offset.zero & boundary.size;
      return rect.intersect(bounds);
    } catch (_) {
      return null;
    }
  }

  static Future<ui.Image?> _toImage(GlobalKey boundaryKey) async {
    final boundary = boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;
    try {
      return await boundary.toImage(pixelRatio: _pixelRatio);
    } catch (e) {
      debugPrint('DevScreenCapture.toImage failed: $e');
      return null;
    }
  }

  static Future<ui.Image?> _captureRegion(GlobalKey boundaryKey, Rect regionLogical) async {
    final full = await _toImage(boundaryKey);
    if (full == null) return null;

    final left = (regionLogical.left * _pixelRatio).round().clamp(0, full.width);
    final top = (regionLogical.top * _pixelRatio).round().clamp(0, full.height);
    final right = (regionLogical.right * _pixelRatio).round().clamp(0, full.width);
    final bottom = (regionLogical.bottom * _pixelRatio).round().clamp(0, full.height);
    final w = right - left;
    final h = bottom - top;
    if (w <= 0 || h <= 0) {
      full.dispose();
      return null;
    }

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      full,
      Rect.fromLTWH(left.toDouble(), top.toDouble(), w.toDouble(), h.toDouble()),
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint(),
    );
    full.dispose();
    final picture = recorder.endRecording();
    return picture.toImage(w, h);
  }

  static Future<ui.Image> _stitchByScrollDeltas({
    required List<ui.Image> slices,
    required List<double> offsets,
    required double viewHLogical,
    required double pixelRatio,
  }) async {
    final width = slices.map((s) => s.width).reduce(math.max);
    final parts = <({ui.Image image, double srcTop, double srcH})>[];

    parts.add((image: slices.first, srcTop: 0, srcH: slices.first.height.toDouble()));

    for (var i = 1; i < slices.length; i++) {
      final delta = offsets[i] - offsets[i - 1];
      final srcTopLogical = (viewHLogical - delta).clamp(0.0, viewHLogical);
      final srcTop = srcTopLogical * pixelRatio;
      final srcH = math.max(0.0, slices[i].height - srcTop);
      if (srcH < 1) continue;
      parts.add((image: slices[i], srcTop: srcTop, srcH: srcH));
    }

    var totalHeight = 0.0;
    for (final p in parts) {
      totalHeight += p.srcH;
    }

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    var dy = 0.0;
    for (final p in parts) {
      final src = Rect.fromLTWH(0, p.srcTop, p.image.width.toDouble(), p.srcH);
      final dst = Rect.fromLTWH(0, dy, p.image.width.toDouble(), p.srcH);
      canvas.drawImageRect(p.image, src, dst, Paint());
      dy += p.srcH;
    }

    final picture = recorder.endRecording();
    return picture.toImage(width, totalHeight.ceil());
  }

  static Future<File> _save(ui.Image image, {required String label}) async {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) {
      throw StateError('PNG encode failed');
    }
    final dir = await outputDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final file = File('${dir.path}/${stamp}_$label.png');
    await file.writeAsBytes(bytes.buffer.asUint8List());
    return file;
  }
}
