import '../models/call_history_entry.dart';
import '../models/contact_trust.dart';
import '../models/message.dart';
import '../utils/format.dart';
import 'contact_store.dart';
import 'contact_trust_store.dart';

class ContactRuntimeService {
  ContactRuntimeService({
    ContactStore? contactStore,
    ContactTrustStore? trustStore,
  }) : _contactStore = contactStore ?? ContactStore(),
       _trustStore = trustStore ?? ContactTrustStore();

  final ContactStore _contactStore;
  final ContactTrustStore _trustStore;

  Map<String, String> _aliases = {};
  Map<String, TrustLevel> _trustLevels = {};
  final Map<String, bool> _online = {};
  final Map<String, DateTime?> _lastSeen = {};

  Map<String, String> get aliases => Map.unmodifiable(_aliases);
  Map<String, TrustLevel> get trustLevels => Map.unmodifiable(_trustLevels);

  Future<void> load() async {
    _aliases = await loadAllContactAliases();
    _trustLevels = await loadAllContactTrust();
    _online.clear();
    _lastSeen.clear();
  }

  void clearRuntime() {
    _aliases = {};
    _trustLevels = {};
    _online.clear();
    _lastSeen.clear();
  }

  Future<void> setAlias(String userId, String name) async {
    final normalized = name.trim();
    await _contactStore.setAlias(userId, normalized);
    _aliases[userId] = normalized;
  }

  TrustLevel trustLevelFor(String userId) =>
      _trustLevels[userId] ?? TrustLevel.unknown;

  /// Seeds the in-memory trust state for a newly discovered conversation
  /// without attempting to mutate the read-only [trustLevels] view.
  void ensureDefaultTrust(String userId) {
    final current = _trustLevels[userId];
    if (current == null || current == TrustLevel.unknown) {
      _trustLevels[userId] = TrustLevel.normal;
    }
  }

  Future<void> setTrust(String userId, TrustLevel level) async {
    await _trustStore.setTrust(userId, level);
    _trustLevels[userId] = level;
  }

  void updatePresence(String userId, Map<String, dynamic> presence) {
    _online[userId] = presence['online'] == true;
    final raw = presence['last_seen'] as String?;
    _lastSeen[userId] = raw == null ? null : DateTime.tryParse(raw)?.toLocal();
  }

  bool isOnline(String userId) => _online[userId] ?? false;

  String statusLabel(
    String userId, {
    required bool isCurrentCallPeer,
    required bool callAnswered,
  }) {
    if (isCurrentCallPeer) return callAnswered ? 'В звонке' : 'Звонит…';
    if (isOnline(userId)) return 'Недавно в сети';
    final last = _lastSeen[userId];
    return last == null ? '' : formatRelativeTime(last);
  }

  DateTime? lastActivity(
    String userId, {
    required Iterable<List<ChatMessage>> messageLists,
    required Iterable<CallHistoryEntry> calls,
  }) {
    DateTime? latest;
    for (final messages in messageLists) {
      for (final message in messages) {
        if (message.senderUserId == userId &&
            (latest == null || message.createdAt.isAfter(latest))) {
          latest = message.createdAt;
        }
      }
    }
    for (final call in calls) {
      if (call.peerUserId == userId &&
          (latest == null || call.startedAt.isAfter(latest))) {
        latest = call.startedAt;
      }
    }
    return latest;
  }
}
