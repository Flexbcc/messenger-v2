import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'settings_runtime.dart';

/// Saves decrypted media to a local gallery-export folder when
/// [media.save_to_gallery] is enabled. No `gal` package — uses path_provider
/// so desktop/web stay supported without extra native permissions.
class GallerySaveService {
  GallerySaveService._();
  static final instance = GallerySaveService._();

  Future<String?> maybeSave({
    required String filename,
    required Uint8List bytes,
  }) async {
    if (!await SettingsRuntime.instance.saveToGallery()) return null;
    if (kIsWeb) return null;
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/gallery_exports');
      if (!await dir.exists()) await dir.create(recursive: true);
      final safe = filename.replaceAll(RegExp(r'[^\w.\-]'), '_');
      final file = File('${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$safe');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }
}
