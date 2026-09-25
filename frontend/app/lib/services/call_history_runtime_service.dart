import '../models/call_history_entry.dart';
import 'call_history_store.dart';

/// Owns the account-scoped in-memory call history and its persistence.
///
/// Keeping the mutation rules here prevents controllers from maintaining a
/// second, subtly different limit from [CallHistoryStore].
class CallHistoryRuntimeService {
  CallHistoryRuntimeService({CallHistoryStore? store})
    : _store = store ?? CallHistoryStore();

  final CallHistoryStore _store;
  List<CallHistoryEntry> _entries = [];

  List<CallHistoryEntry> get entries => List.unmodifiable(_entries);

  Future<void> load() async {
    _entries = await _store.loadAll();
  }

  Future<void> append(CallHistoryEntry entry) async {
    _entries = await _store.append(entry);
  }

  Future<void> clear() async {
    await _store.clear();
    _entries = [];
  }

  void clearRuntime() {
    _entries = [];
  }
}
