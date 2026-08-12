/// Remote release manifest served at `{gateway}/releases/clients/manifest.json`.
class ClientReleaseManifest {
  const ClientReleaseManifest({
    required this.channel,
    required this.updatedAt,
    required this.messenger,
  });

  final String channel;
  final String? updatedAt;
  final ProductRelease messenger;

  factory ClientReleaseManifest.fromJson(Map<String, dynamic> json) {
    final products = json['products'] as Map<String, dynamic>? ?? {};
    return ClientReleaseManifest(
      channel: json['channel'] as String? ?? 'stable',
      updatedAt: json['updated_at'] as String?,
      messenger: ProductRelease.fromJson(
        products['messenger'] as Map<String, dynamic>? ?? {},
      ),
    );
  }
}

class ProductRelease {
  const ProductRelease({
    required this.version,
    required this.build,
    required this.channel,
    required this.releaseNotes,
    required this.platforms,
  });

  final String version;
  final int build;
  final String channel;
  final String releaseNotes;
  final Map<String, PlatformRelease> platforms;

  factory ProductRelease.fromJson(Map<String, dynamic> json) {
    final raw = json['platforms'] as Map<String, dynamic>? ?? {};
    return ProductRelease(
      version: json['version'] as String? ?? '0.0.0',
      build: (json['build'] as num?)?.toInt() ?? 0,
      channel: json['channel'] as String? ?? 'stable',
      releaseNotes: json['release_notes'] as String? ?? '',
      platforms: raw.map(
        (k, v) =>
            MapEntry(k, PlatformRelease.fromJson(v as Map<String, dynamic>)),
      ),
    );
  }

  PlatformRelease? forPlatform(String platform) => platforms[platform];
}

class PlatformRelease {
  const PlatformRelease({
    required this.version,
    required this.build,
    required this.available,
    required this.updateKind,
    this.downloadUrl,
    this.minVersion,
  });

  final String version;
  final int build;
  final bool available;

  /// `reload` (PWA), `download` (native zip/apk), `store` (App Store).
  final String updateKind;
  final String? downloadUrl;
  final String? minVersion;

  factory PlatformRelease.fromJson(Map<String, dynamic> json) {
    return PlatformRelease(
      version: json['version'] as String? ?? '0.0.0',
      build: (json['build'] as num?)?.toInt() ?? 0,
      available: json['available'] as bool? ?? false,
      updateKind: json['update_kind'] as String? ?? 'download',
      downloadUrl: json['download_url'] as String?,
      minVersion: json['min_version'] as String?,
    );
  }
}

/// Compare semver `a.b.c` then build number.
int compareSemverBuild(String aVer, int aBuild, String bVer, int bBuild) {
  final av = _parseParts(aVer);
  final bv = _parseParts(bVer);
  for (var i = 0; i < 3; i++) {
    final d = av[i].compareTo(bv[i]);
    if (d != 0) return d;
  }
  return aBuild.compareTo(bBuild);
}

List<int> _parseParts(String v) {
  final core = v.split('-').first;
  final parts = core.split('.');
  return [
    int.tryParse(parts.elementAtOrNull(0) ?? '0') ?? 0,
    int.tryParse(parts.elementAtOrNull(1) ?? '0') ?? 0,
    int.tryParse(parts.elementAtOrNull(2) ?? '0') ?? 0,
  ];
}

bool isRemoteNewer({
  required String localVersion,
  required int localBuild,
  required String remoteVersion,
  required int remoteBuild,
}) {
  return compareSemverBuild(
        localVersion,
        localBuild,
        remoteVersion,
        remoteBuild,
      ) <
      0;
}
