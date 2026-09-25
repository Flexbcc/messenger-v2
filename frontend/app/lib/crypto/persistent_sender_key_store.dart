import 'dart:convert';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../security/crypto_encoding.dart';
import 'encrypted_preference_store.dart';

/// Persists group sender-key state (0301_GROUP_MESSAGING.md) across
/// restarts — the group-chat counterpart of PersistentSignalProtocolStore,
/// same rationale (see its doc comment): losing this on every reload used
/// to make prior group messages permanently undecryptable.
///
/// Mirrors `InMemorySenderKeyStore`'s semantics: `loadSenderKey` returns a
/// fresh empty `SenderKeyRecord` when absent (not an error) — callers
/// don't null-check.
class PersistentSenderKeyStore extends SenderKeyStore {
  PersistentSenderKeyStore(SharedPreferences prefs)
    : _encrypted = EncryptedPreferenceStore(prefs);

  final EncryptedPreferenceStore _encrypted;

  static const _prefix = 'sp_senderkey_v1::';

  String _key(SenderKeyName name) => '$_prefix${name.serialize()}';

  @override
  Future<SenderKeyRecord> loadSenderKey(SenderKeyName senderKeyName) async {
    final b64 = await _encrypted.read(_key(senderKeyName));
    if (b64 == null) return SenderKeyRecord();
    return SenderKeyRecord.fromSerialized(
      decodeBase64Bounded(
        b64,
        minimumBytes: 1,
        maximumBytes: 4 * 1024 * 1024,
        field: 'Signal sender-key record',
        maxEncodedCharacters: 6 * 1024 * 1024,
      ),
    );
  }

  @override
  Future<void> storeSenderKey(
    SenderKeyName senderKeyName,
    SenderKeyRecord record,
  ) async {
    await _encrypted.write(
      _key(senderKeyName),
      base64Encode(record.serialize()),
    );
  }
}
