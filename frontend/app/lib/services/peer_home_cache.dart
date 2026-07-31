import '../models/peer_home_entry.dart';
import 'local_settings_store.dart';

/// Locally cached last-known Home node per peer user, fed by the realtime
/// `home_changed` CONTROL notify (see AppController._onRealtimeEvent,
/// docs/reality/R4-routing.md Gaps "Нет notify смены Home"). Best-effort
/// only — actual routing stays fully server-side; this just lets the UI
/// show where a contact's Home last moved to.
class PeerHomeCache {
  PeerHomeCache._();
  static final instance = PeerHomeCache._();

  final _store = LocalSettingsStore();

  String _key(String userId) => 'peer_home_$userId';

  Future<PeerHomeEntry?> get(String userId) async {
    final raw = await _store.getString(_key(userId), '');
    return PeerHomeEntry.decode(raw);
  }

  /// Most recent `home_changed` notify this session — diagnostics/connection
  /// status display only, not persisted.
  String? lastUserId;
  PeerHomeEntry? lastEntry;

  Future<void> set(String userId, {required String homeUrl, DateTime? updatedAt}) async {
    final entry = PeerHomeEntry(
      homeUrl: homeUrl,
      updatedAt: updatedAt,
      cachedAt: DateTime.now(),
    );
    await _store.setString(_key(userId), entry.encode());
    lastUserId = userId;
    lastEntry = entry;
  }

  Future<void> remove(String userId) async {
    await _store.remove(_key(userId));
  }
}
