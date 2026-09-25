import '../models/duress_policy.dart';
import '../security/device_crypto.dart';
import 'local_settings_store.dart';

/// Device-bound runtime mirror — counters & lockout readable without PIN.
class DuressRuntimeStore {
  DuressRuntimeStore._();
  static final instance = DuressRuntimeStore._();

  static const _prefsKey = 'duress_runtime_packed_v1';
  final _crypto = DeviceCrypto.instance;
  final _store = LocalSettingsStore();

  Future<DuressPolicyData> loadMirror() async {
    final packed = await _store.getString(_prefsKey, '');
    if (packed.isEmpty) return DuressPolicyData.withPreset('P2');
    final json = await _crypto.decryptJson(packed);
    if (json == null) return DuressPolicyData.withPreset('P2');
    return DuressPolicyData.fromJson(json);
  }

  Future<void> saveMirror(DuressPolicyData data) async {
    final packed = await _crypto.encryptJson(data.toJson());
    await _store.setString(_prefsKey, packed);
  }

  Future<void> clear() async {
    await _store.remove(_prefsKey);
  }
}
