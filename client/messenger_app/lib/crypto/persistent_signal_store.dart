import 'dart:convert';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists Signal Protocol client state (sessions, one-time prekeys,
/// signed prekey, trusted remote identities) across restarts, backed by
/// SharedPreferences — same "not OS-keychain-grade" MVP posture as the rest
/// of local storage (see ADR-0005, services/session_store.dart).
///
/// Without this, `InMemorySignalProtocolStore` threw all of the above away
/// on every page reload: the identity key itself was already persisted,
/// but the established Double Ratchet session for each contact was not —
/// so after a reload, every prior message (sent or received) became
/// permanently undecryptable. That's not a bug in the crypto (forward
/// secrecy correctly means losing session state loses old message keys
/// forever) — it's that the session state was being lost when it didn't
/// need to be.
///
/// Semantics deliberately mirror `InMemorySignalProtocolStore`'s reference
/// implementations (see libsignal_protocol_dart's
/// `state/impl/in_memory_*_store.dart`): `loadSession` returns a fresh
/// empty `SessionRecord` when absent (not an error); `loadPreKey`/
/// `loadSignedPreKey` throw `InvalidKeyIdException` when absent; identity
/// trust is trust-on-first-use per contact device.
class PersistentSignalProtocolStore implements SignalProtocolStore {
  PersistentSignalProtocolStore(this._prefs, this._identityKeyPair, this._registrationId);

  final SharedPreferences _prefs;
  final IdentityKeyPair _identityKeyPair;
  final int _registrationId;

  static const _sessionPrefix = 'sp_session_v1::';
  static const _preKeyPrefix = 'sp_prekey_v1::';
  static const _signedPreKeyPrefix = 'sp_signedprekey_v1::';
  static const _identityPrefix = 'sp_identity_v1::';

  String _sessionKey(SignalProtocolAddress a) => '$_sessionPrefix${a.getName()}::${a.getDeviceId()}';
  String _identityKey(SignalProtocolAddress a) => '$_identityPrefix${a.getName()}::${a.getDeviceId()}';

  // --- IdentityKeyStore ---

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async => _identityKeyPair;

  @override
  Future<int> getLocalRegistrationId() async => _registrationId;

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    final b64 = _prefs.getString(_identityKey(address));
    if (b64 == null) return null;
    return IdentityKey.fromBytes(base64Decode(b64), 0);
  }

  @override
  Future<bool> saveIdentity(SignalProtocolAddress address, IdentityKey? identityKey) async {
    if (identityKey == null) return false;
    final existing = await getIdentity(address);
    if (existing == identityKey) return false;
    await _prefs.setString(_identityKey(address), base64Encode(identityKey.serialize()));
    return true;
  }

  @override
  Future<bool> isTrustedIdentity(SignalProtocolAddress address, IdentityKey? identityKey, Direction direction) async {
    if (identityKey == null) return false;
    final trusted = await getIdentity(address);
    return trusted == null || trusted == identityKey;
  }

  // --- PreKeyStore ---

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final b64 = _prefs.getString('$_preKeyPrefix$preKeyId');
    if (b64 == null) throw InvalidKeyIdException('No such prekeyrecord! - $preKeyId');
    return PreKeyRecord.fromBuffer(base64Decode(b64));
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    await _prefs.setString('$_preKeyPrefix$preKeyId', base64Encode(record.serialize()));
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async => _prefs.containsKey('$_preKeyPrefix$preKeyId');

  @override
  Future<void> removePreKey(int preKeyId) async => _prefs.remove('$_preKeyPrefix$preKeyId');

  // --- SignedPreKeyStore ---

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final b64 = _prefs.getString('$_signedPreKeyPrefix$signedPreKeyId');
    if (b64 == null) throw InvalidKeyIdException('No such signedprekeyrecord! $signedPreKeyId');
    return SignedPreKeyRecord.fromSerialized(base64Decode(b64));
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    return [
      for (final key in _prefs.getKeys().where((k) => k.startsWith(_signedPreKeyPrefix)))
        SignedPreKeyRecord.fromSerialized(base64Decode(_prefs.getString(key)!)),
    ];
  }

  @override
  Future<void> storeSignedPreKey(int signedPreKeyId, SignedPreKeyRecord record) async {
    await _prefs.setString('$_signedPreKeyPrefix$signedPreKeyId', base64Encode(record.serialize()));
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async => _prefs.containsKey('$_signedPreKeyPrefix$signedPreKeyId');

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async => _prefs.remove('$_signedPreKeyPrefix$signedPreKeyId');

  // --- SessionStore ---

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    final b64 = _prefs.getString(_sessionKey(address));
    if (b64 == null) return SessionRecord();
    return SessionRecord.fromSerialized(base64Decode(b64));
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    final prefix = '$_sessionPrefix$name::';
    return [
      for (final key in _prefs.getKeys().where((k) => k.startsWith(prefix)))
        if (int.tryParse(key.substring(prefix.length)) case final deviceId? when deviceId != 1) deviceId,
    ];
  }

  @override
  Future<void> storeSession(SignalProtocolAddress address, SessionRecord record) async {
    await _prefs.setString(_sessionKey(address), base64Encode(record.serialize()));
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async => _prefs.containsKey(_sessionKey(address));

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async => _prefs.remove(_sessionKey(address));

  @override
  Future<void> deleteAllSessions(String name) async {
    final prefix = '$_sessionPrefix$name::';
    for (final key in _prefs.getKeys().where((k) => k.startsWith(prefix)).toList()) {
      await _prefs.remove(key);
    }
  }

  /// Returns the count of stored (unconsumed) one-time prekeys.
  int countStoredPreKeys() {
    return _prefs.getKeys().where((k) => k.startsWith(_preKeyPrefix)).length;
  }

  /// Returns the max stored prekey ID so new IDs don't collide.
  int maxPreKeyId() {
    final ids = _prefs
        .getKeys()
        .where((k) => k.startsWith(_preKeyPrefix))
        .map((k) => int.tryParse(k.substring(_preKeyPrefix.length)) ?? 0);
    return ids.isEmpty ? 0 : ids.reduce((a, b) => a > b ? a : b);
  }
}
