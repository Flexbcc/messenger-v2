import 'package:flutter/foundation.dart';

import '../models/contact_trust.dart';
import 'local_settings_store.dart';
import 'settings_runtime.dart';

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

  /// Returns false when [knownSizeBytes] exceeds [SettingsRuntime.maxAutoloadMb].
  /// Unknown size (`null`) does not block; callers use force/tap-to-load to bypass.
  Future<bool> shouldDownload(MediaKind kind, {int? knownSizeBytes}) async {
    final mode = await modeFor(kind);
    var networkOk = switch (mode) {
      AutoDownloadMode.never => false,
      AutoDownloadMode.wifi => _isUnmetered(),
      AutoDownloadMode.wifiAndMobile => true,
    };
    if (networkOk && mode == AutoDownloadMode.wifiAndMobile) {
      // Catalog `node.mobile_data=false` forces Wi‑Fi-only behaviour.
      if (!await SettingsRuntime.instance.nodeMobileData() && !_isUnmetered()) {
        networkOk = false;
      }
      // `node.roaming=false` blocks autodownload on metered/cellular like mobile_data.
      if (networkOk &&
          !await SettingsRuntime.instance.nodeRoaming() &&
          !_isUnmetered()) {
        networkOk = false;
      }
    }
    if (!networkOk) return false;
    return _withinAutoloadLimit(knownSizeBytes);
  }

  /// Combines global download prefs with per-contact [trust].
  Future<bool> shouldDownloadForSender(
    MediaKind kind,
    TrustLevel trust, {
    int? knownSizeBytes,
  }) async {
    final trustLevelsOn = await SettingsRuntime.instance.contactsTrustLevelsEnabled();
    final effective = trustLevelsOn ? trust : TrustLevel.normal;
    final trustOk = switch (effective) {
      TrustLevel.unknown => false,
      TrustLevel.normal => true,
      TrustLevel.trusted => kind == MediaKind.photos,
      TrustLevel.highTrust => true,
    };
    if (!trustOk) return false;
    return shouldDownload(kind, knownSizeBytes: knownSizeBytes);
  }

  Future<bool> _withinAutoloadLimit(int? knownSizeBytes) async {
    if (knownSizeBytes == null || knownSizeBytes <= 0) return true;
    final maxMb = await SettingsRuntime.instance.maxAutoloadMb();
    final limitBytes = maxMb * 1024 * 1024;
    return knownSizeBytes <= limitBytes;
  }

  bool _isUnmetered() {
    // Web/desktop treated as unmetered; mobile would need connectivity_plus later.
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
  }
}
