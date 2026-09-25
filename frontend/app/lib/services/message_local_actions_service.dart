import 'dart:collection';

import 'message_local_actions_store.dart';

/// Account-scoped runtime state for device-only hide and pin actions.
class MessageLocalActionsService {
  MessageLocalActionsService({MessageLocalActionsStore? store})
    : _store = store ?? MessageLocalActionsStore.instance;

  final MessageLocalActionsStore _store;
  final Set<String> _hiddenIds = {};
  final Set<String> _pinnedIds = {};

  Set<String> get hiddenIds => UnmodifiableSetView(_hiddenIds);

  bool isPinned(String messageId) => _pinnedIds.contains(messageId);

  Future<void> load(String userId) async {
    final values = await Future.wait([
      _store.loadHidden(userId),
      _store.loadPinned(userId),
    ]);
    _hiddenIds
      ..clear()
      ..addAll(values[0]);
    _pinnedIds
      ..clear()
      ..addAll(values[1]);
  }

  void clear() {
    _hiddenIds.clear();
    _pinnedIds.clear();
  }

  Future<void> hide(String userId, String messageId) async {
    if (!_hiddenIds.add(messageId)) return;
    try {
      await _store.hideMessage(userId, messageId);
    } catch (_) {
      _hiddenIds.remove(messageId);
      rethrow;
    }
  }

  Future<bool> togglePinned(String userId, String messageId) async {
    final wasPinned = _pinnedIds.contains(messageId);
    if (wasPinned) {
      _pinnedIds.remove(messageId);
    } else {
      _pinnedIds.add(messageId);
    }
    try {
      await _store.setPinned(userId, messageId, !wasPinned);
      return !wasPinned;
    } catch (_) {
      if (wasPinned) {
        _pinnedIds.add(messageId);
      } else {
        _pinnedIds.remove(messageId);
      }
      rethrow;
    }
  }
}
