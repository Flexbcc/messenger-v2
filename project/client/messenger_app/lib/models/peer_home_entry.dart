/// A peer's last known Home node URL, as reported by our own Home via the
/// realtime `home_changed` CONTROL notify (docs/reality/R4-routing.md Gaps
/// "Нет notify смены Home"). Local cache only — routing stays server-side.
class PeerHomeEntry {
  const PeerHomeEntry({
    required this.homeUrl,
    this.updatedAt,
    required this.cachedAt,
  });

  final String homeUrl;

  /// Server-reported `home_updated_at`, when present.
  final DateTime? updatedAt;

  /// When this device received the notify — always set, used as a fallback
  /// for display when [updatedAt] is absent.
  final DateTime cachedAt;

  String encode() => [
        homeUrl,
        updatedAt?.toIso8601String() ?? '',
        cachedAt.toIso8601String(),
      ].join('|');

  static PeerHomeEntry? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final p = raw.split('|');
    if (p.length < 3 || p[0].isEmpty) return null;
    return PeerHomeEntry(
      homeUrl: p[0],
      updatedAt: p[1].isEmpty ? null : DateTime.tryParse(p[1]),
      cachedAt: DateTime.tryParse(p[2]) ?? DateTime.now(),
    );
  }
}
