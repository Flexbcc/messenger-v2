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
    final schema = json['schema'];
    final channel = json['channel'];
    final updatedAt = json['updated_at'];
    final products = json['products'];
    if (schema != 1) {
      throw const FormatException('unsupported release manifest schema');
    }
    if (channel is! String || !_channels.contains(channel)) {
      throw const FormatException('release manifest channel is invalid');
    }
    if (updatedAt != null &&
        (updatedAt is! String ||
            updatedAt.length > 64 ||
            DateTime.tryParse(updatedAt) == null)) {
      throw const FormatException('release manifest timestamp is invalid');
    }
    if (products is! Map<String, dynamic>) {
      throw const FormatException('release manifest products are invalid');
    }
    final messenger = products['messenger'];
    if (messenger is! Map<String, dynamic>) {
      throw const FormatException('messenger release is missing');
    }
    return ClientReleaseManifest(
      channel: channel,
      updatedAt: updatedAt as String?,
      messenger: ProductRelease.fromJson(messenger),
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
    final version = _version(json['version'], 'product version');
    final build = _nonNegativeInt(json['build'], 'product build');
    final channel = json['channel'];
    final releaseNotes = json['release_notes'];
    final raw = json['platforms'];
    if (channel is! String || !_channels.contains(channel)) {
      throw const FormatException('product release channel is invalid');
    }
    if (releaseNotes is! String || releaseNotes.length > 16384) {
      throw const FormatException('release notes are invalid');
    }
    if (raw is! Map<String, dynamic> || raw.length > 16) {
      throw const FormatException('release platforms are invalid');
    }
    final platforms = <String, PlatformRelease>{};
    for (final entry in raw.entries) {
      if (!_platforms.contains(entry.key) ||
          entry.value is! Map<String, dynamic>) {
        throw const FormatException('release platform entry is invalid');
      }
      platforms[entry.key] = PlatformRelease.fromJson(
        entry.value as Map<String, dynamic>,
      );
    }
    return ProductRelease(
      version: version,
      build: build,
      channel: channel,
      releaseNotes: releaseNotes,
      platforms: platforms,
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
    final version = _version(json['version'], 'platform version');
    final build = _nonNegativeInt(json['build'], 'platform build');
    final available = json['available'];
    final updateKind = json['update_kind'];
    final downloadUrl = json['download_url'];
    final minVersion = json['min_version'];
    if (available is! bool) {
      throw const FormatException('platform available must be a boolean');
    }
    if (updateKind is! String ||
        !const {'reload', 'download', 'store'}.contains(updateKind)) {
      throw const FormatException('unsupported update kind');
    }
    if (downloadUrl != null && downloadUrl is! String) {
      throw const FormatException('download URL must be a string');
    }
    if (minVersion != null) {
      _version(minVersion, 'minimum version');
    }
    return PlatformRelease(
      version: version,
      build: build,
      available: available,
      updateKind: updateKind,
      downloadUrl: downloadUrl as String?,
      minVersion: minVersion as String?,
    );
  }
}

final RegExp _semverPattern = RegExp(
  r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]{1,32})?$',
);

const _channels = {'stable', 'beta', 'alpha'};
const _platforms = {'web', 'macos', 'windows', 'linux', 'android', 'ios'};

String _version(Object? value, String field) {
  if (value is! String ||
      value.length > 64 ||
      !_semverPattern.hasMatch(value)) {
    throw FormatException('$field is invalid');
  }
  return value;
}

int _nonNegativeInt(Object? value, String field) {
  if (value is! num || !value.isFinite || value != value.toInt()) {
    throw FormatException('$field must be an integer');
  }
  final result = value.toInt();
  if (result < 0 || result > 2147483647) {
    throw FormatException('$field is outside the supported range');
  }
  return result;
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
