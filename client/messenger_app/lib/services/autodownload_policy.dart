import 'package:flutter/foundation.dart';

import '../models/contact_trust.dart';
import 'local_settings_store.dart';

enum MediaKind { photos, videos, files, audio }

enum AutoDownloadMode { never, wifi, wifiAndMobile }

/// Whether to fetch media bytes now — reads persisted Data & Storage prefs.
class AutodownloadPolicy {
  AutodownloadPolicy._();
  static final instance = AutodownloadPolicy._();

  final _store = LocalSettingsStore();

  Future<AutoDownloadMode> modeFor(MediaKind kind) async {
    final key = switch (kind) {
      MediaKind.photos => 'dl_photos',
      MediaKind.videos => 'dl_videos',
      MediaKind.files => 'dl_files',
      MediaKind.audio => 'dl_audio',
    };
    final raw = await _store.getString(key, AutoDownloadMode.wifi.name);
    return AutoDownloadMode.values.byName(raw);
  }

  Future<bool> shouldDownload(MediaKind kind) async {
    final mode = await modeFor(kind);
    return switch (mode) {
      AutoDownloadMode.never => false,
      AutoDownloadMode.wifi => _isUnmetered(),
      AutoDownloadMode.wifiAndMobile => true,
    };
  }

  /// Combines global download prefs with per-contact [trust].
  Future<bool> shouldDownloadForSender(MediaKind kind, TrustLevel trust) async {
    final trustOk = switch (trust) {
      TrustLevel.unknown => false,
      TrustLevel.normal => true,
      TrustLevel.trusted => kind == MediaKind.photos,
      TrustLevel.highTrust => true,
    };
    if (!trustOk) return false;
    return shouldDownload(kind);
  }

  bool _isUnmetered() {
    // Web/desktop treated as unmetered; mobile would need connectivity_plus later.
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
  }
}
