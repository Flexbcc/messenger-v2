import 'package:flutter/foundation.dart';

import '../models/duress_policy.dart';
import 'catalog_list_store.dart';
import 'duress_policy_store.dart';
import 'duress_runtime_store.dart';
import 'local_settings_store.dart';
import 'trusted_contacts_store.dart';

/// In-memory policy after PIN unlock; syncs encrypted + runtime stores.
class DuressPolicySession {
  DuressPolicySession._();
  static final instance = DuressPolicySession._();

  DuressPolicyData? _data;
  String? _pin;
  bool _unlocked = false;

  bool get isUnlocked => _unlocked;
  DuressPolicyData? get data => _data;

  Future<bool> unlock(String pin) async {
    var loaded = await DuressPolicyStore.instance.load(pin);
    loaded ??= DuressPolicyData.withPreset('P2');
    await _migrateLegacy(loaded);
    final mirror = await DuressRuntimeStore.instance.loadMirror();
    _mergeRuntime(loaded, mirror);
    _data = loaded;
    _pin = pin;
    _unlocked = true;
    await _persist();
    return true;
  }

  void lock() {
    _pin = null;
    _data = null;
    _unlocked = false;
  }

  Future<void> wipe() async {
    await DuressPolicyStore.instance.wipe();
    await DuressRuntimeStore.instance.clear();
    lock();
  }

  Future<void> setPreset(String presetId) async {
    if (_data == null || _pin == null) return;
    if (presetId == DuressPresets.customId) {
      _data!.presetId = DuressPresets.customId;
    } else {
      _data!.presetId = presetId;
      _data!.rules = List.from(DuressPresets.rulesFor(presetId));
    }
    await _persist();
  }

  Future<void> setRules(List<DuressRule> rules) async {
    if (_data == null) return;
    _data!.presetId = DuressPresets.customId;
    _data!.rules = List.from(rules);
    await _persist();
  }

  Future<void> setTrustedUserIds(List<String> ids) async {
    if (_data == null) return;
    _data!.trustedUserIds = ids
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    await _persist();
  }

  Future<void> setTrustedChannels(List<String> channels) async {
    if (_data == null) return;
    _data!.trustedChannels = DuressTrustedChannels.normalize(channels);
    await _persist();
  }

  Future<void> addTrusted(String userId) async {
    if (_data == null) return;
    if (_data!.trustedUserIds.contains(userId)) return;
    _data!.trustedUserIds.add(userId);
    await _persist();
  }

  Future<void> removeTrusted(String userId) async {
    if (_data == null) return;
    _data!.trustedUserIds.remove(userId);
    await _persist();
  }

  Future<void> _persist() async {
    if (_data == null || _pin == null) return;
    await DuressPolicyStore.instance.save(_pin!, _data!);
    await DuressRuntimeStore.instance.saveMirror(_data!);
  }

  void _mergeRuntime(DuressPolicyData target, DuressPolicyData mirror) {
    if (mirror.presetId.isNotEmpty) target.presetId = mirror.presetId;
    target.lockoutUntil = mirror.lockoutUntil;
    for (final entry in mirror.counters.entries) {
      target.counters[entry.key] = entry.value;
    }
    if (target.trustedUserIds.isEmpty && mirror.trustedUserIds.isNotEmpty) {
      target.trustedUserIds = List.from(mirror.trustedUserIds);
    }
    if (mirror.trustedChannels.isNotEmpty) {
      target.trustedChannels = List.from(mirror.trustedChannels);
    }
  }

  Future<void> _migrateLegacy(DuressPolicyData data) async {
    if (data.trustedUserIds.isNotEmpty) return;
    // Prefer catalog trusted list when contacts.trusted_enabled is on.
    final catalogTrusted = await CatalogListStore().load(
      'contacts.trusted_list',
    );
    if (catalogTrusted.isNotEmpty) {
      data.trustedUserIds = catalogTrusted;
      return;
    }
    final legacy = await TrustedContactsStore.instance.load();
    if (legacy.isEmpty) return;
    data.trustedUserIds = legacy;
    debugPrint(
      'DuressPolicySession: migrated ${legacy.length} trusted contacts',
    );
  }

  Future<void> migrateDecoyCounter() async {
    final store = LocalSettingsStore();
    final legacy = await store.getInt('decoy_pin_entry_count', 0);
    if (legacy <= 0 || _data == null) return;
    final c = _data!.counterFor(DuressTrigger.decoyPinStreak);
    if (c.count < legacy) c.count = legacy;
    await store.setInt('decoy_pin_entry_count', 0);
  }

  Future<void> syncFrom(DuressPolicyData data) async {
    if (_data == null) return;
    _data!.lockoutUntil = data.lockoutUntil;
    _data!.counters
      ..clear()
      ..addAll(data.counters);
    await migrateDecoyCounter();
    await _persist();
  }
}
