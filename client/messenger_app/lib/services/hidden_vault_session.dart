import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/hidden_chat.dart';
import 'hidden_vault_store.dart';

/// In-memory unlocked vault — only available after correct PIN entry.
class HiddenVaultSession extends ChangeNotifier {
  HiddenVaultSession._();
  static final instance = HiddenVaultSession._();

  static const _uuid = Uuid();

  HiddenVaultData? _data;
  String? _pin;
  String? _sessionPin;
  bool _unlocked = false;

  bool get isUnlocked => _unlocked;
  List<HiddenChat> get chats => List.unmodifiable(_data?.chats ?? const []);

  /// Re-open vault using PIN from the current app session (mock biometric).
  Future<bool> unlockFromSession() async {
    final pin = _sessionPin;
    if (pin == null) return false;
    return unlock(pin);
  }

  Future<bool> unlock(String pin) async {
    final loaded = await HiddenVaultStore.instance.load(pin);
    if (loaded == null) return false;
    _pin = pin;
    _sessionPin = pin;
    _data = _pruneExpired(loaded);
    _unlocked = true;
    notifyListeners();
    return true;
  }

  void lock() {
    _pin = null;
    _sessionPin = null;
    _data = null;
    _unlocked = false;
    notifyListeners();
  }

  Future<void> wipe() async {
    await HiddenVaultStore.instance.wipe();
    _sessionPin = null;
    lock();
  }

  HiddenChat? chatById(String id) {
    if (_data == null) return null;
    for (final c in _data!.chats) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<HiddenChat?> createChat(String name) async {
    if (_pin == null || _data == null) return null;
    final chat = HiddenChat(id: _uuid.v4(), name: name.trim());
    if (chat.name.isEmpty) return null;
    _data = _data!.copyWith(chats: [chat, ..._data!.chats]);
    await _persist();
    notifyListeners();
    return chat;
  }

  Future<void> addMessage({
    required String chatId,
    required String text,
    required bool isMine,
  }) async {
    if (_pin == null || _data == null) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final msg = HiddenMessage(id: _uuid.v4(), text: trimmed, isMine: isMine);
    final updated = _data!.chats.map((c) {
      if (c.id != chatId) return c;
      return c.copyWith(
        messages: [...c.messages, msg],
        updatedAt: DateTime.now(),
      );
    }).toList();

    _data = _data!.copyWith(chats: updated);
    await _persist();
    notifyListeners();
  }

  Future<void> setDisappearingTimer(String chatId, String timer) async {
    if (_pin == null || _data == null) return;
    final updated = _data!.chats.map((c) {
      if (c.id != chatId) return c;
      return c.copyWith(disappearingTimer: timer, updatedAt: DateTime.now());
    }).toList();
    _data = _data!.copyWith(chats: updated);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    if (_pin == null || _data == null) return;
    await HiddenVaultStore.instance.save(_pin!, _data!);
  }

  HiddenVaultData _pruneExpired(HiddenVaultData data) {
    final now = DateTime.now();
    final chats = data.chats.map((chat) {
      final maxAge = _maxAge(chat.disappearingTimer);
      if (maxAge == null) return chat;
      final kept = chat.messages.where((m) => now.difference(m.createdAt) < maxAge).toList();
      return chat.copyWith(messages: kept);
    }).toList();
    return data.copyWith(chats: chats);
  }

  Duration? _maxAge(String timer) => switch (timer) {
        'oneHour' => const Duration(hours: 1),
        'oneDay' => const Duration(days: 1),
        'oneWeek' => const Duration(days: 7),
        _ => null,
      };
}
