import 'package:shared_preferences/shared_preferences.dart';

import '../models/duress_policy.dart';
import '../security/device_crypto.dart';

/// Device-bound runtime mirror — counters & lockout readable without PIN.
class DuressRuntimeStore {
  DuressRuntimeStore._();
  static final instance = DuressRuntimeStore._();

  static const _prefsKey = 'duress_runtime_packed_v1';
  final _crypto = DeviceCrypto.instance;

  Future<DuressPolicyData> loadMirror() async {
    final prefs = await SharedPreferences.getInstance();
    final packed = prefs.getString(_prefsKey);
    if (packed == null) return DuressPolicyData.withPreset('P2');
    final json = await _crypto.decryptJson(packed);
    if (json == null) return DuressPolicyData.withPreset('P2');
    return DuressPolicyData.fromJson(json);
  }

  Future<void> saveMirror(DuressPolicyData data) async {
    final packed = await _crypto.encryptJson(data.toJson());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, packed);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}
