import 'dart:convert';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists group sender-key state (0301_GROUP_MESSAGING.md) across
/// restarts — the group-chat counterpart of PersistentSignalProtocolStore,
/// same rationale (see its doc comment): losing this on every reload used
/// to make prior group messages permanently undecryptable.
///
/// Mirrors `InMemorySenderKeyStore`'s semantics: `loadSenderKey` returns a
/// fresh empty `SenderKeyRecord` when absent (not an error) — callers
/// don't null-check.
class PersistentSenderKeyStore extends SenderKeyStore {
  PersistentSenderKeyStore(this._prefs);

  final SharedPreferences _prefs;

  static const _prefix = 'sp_senderkey_v1::';

  String _key(SenderKeyName name) => '$_prefix${name.serialize()}';

  @override
  Future<SenderKeyRecord> loadSenderKey(SenderKeyName senderKeyName) async {
    final b64 = _prefs.getString(_key(senderKeyName));
    if (b64 == null) return SenderKeyRecord();
    return SenderKeyRecord.fromSerialized(base64Decode(b64));
  }

  @override
  Future<void> storeSenderKey(SenderKeyName senderKeyName, SenderKeyRecord record) async {
    await _prefs.setString(_key(senderKeyName), base64Encode(record.serialize()));
  }
}
