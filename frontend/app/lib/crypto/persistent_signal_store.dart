import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../security/crypto_encoding.dart';
import 'encrypted_preference_store.dart';

/// Persists Signal Protocol client state (sessions, one-time prekeys,
/// signed prekey, trusted remote identities) across restarts. Values are
/// encrypted at rest with the device-bound AES-GCM key before being stored in
/// SharedPreferences. Existing plaintext Base64 records are migrated on read.
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
  PersistentSignalProtocolStore(
    this._prefs,
    this._identityKeyPair,
    this._registrationId,
  ) : _encrypted = EncryptedPreferenceStore(_prefs);

  final SharedPreferences _prefs;
  final IdentityKeyPair _identityKeyPair;
  final int _registrationId;
  final EncryptedPreferenceStore _encrypted;

  static const _sessionPrefix = 'sp_session_v1::';
  static const _preKeyPrefix = 'sp_prekey_v1::';
  static const _signedPreKeyPrefix = 'sp_signedprekey_v1::';
  static const _identityPrefix = 'sp_identity_v1::';

  String _sessionKey(SignalProtocolAddress a) =>
      '$_sessionPrefix${a.getName()}::${a.getDeviceId()}';
  String _identityKey(SignalProtocolAddress a) =>
      '$_identityPrefix${a.getName()}::${a.getDeviceId()}';

  // --- IdentityKeyStore ---

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async => _identityKeyPair;

  @override
  Future<int> getLocalRegistrationId() async => _registrationId;

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    final b64 = await _encrypted.read(_identityKey(address));
    if (b64 == null) return null;
    return IdentityKey.fromBytes(
      decodeBase64Exact(
        b64,
        expectedBytes: 33,
        field: 'stored Signal identity',
        maxEncodedCharacters: 128,
      ),
      0,
    );
  }

  @override
  Future<bool> saveIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
  ) async {
    if (identityKey == null) return false;
    final existing = await getIdentity(address);
    if (existing == identityKey) return false;
    await _encrypted.write(
      _identityKey(address),
      base64Encode(identityKey.serialize()),
    );
    return true;
  }

  @override
  Future<bool> isTrustedIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
    Direction direction,
  ) async {
    if (identityKey == null) return false;
    final trusted = await getIdentity(address);
    return trusted == null || trusted == identityKey;
  }

  // --- PreKeyStore ---

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final b64 = await _encrypted.read('$_preKeyPrefix$preKeyId');
    if (b64 == null) {
      throw InvalidKeyIdException('No such prekeyrecord! - $preKeyId');
    }
    return PreKeyRecord.fromBuffer(_decodeRecord(b64, 'Signal prekey'));
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    await _encrypted.write(
      '$_preKeyPrefix$preKeyId',
      base64Encode(record.serialize()),
    );
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async =>
      _encrypted.contains('$_preKeyPrefix$preKeyId');

  @override
  Future<void> removePreKey(int preKeyId) async =>
      _removeStored('$_preKeyPrefix$preKeyId');

  // --- SignedPreKeyStore ---

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final b64 = await _encrypted.read('$_signedPreKeyPrefix$signedPreKeyId');
    if (b64 == null) {
      throw InvalidKeyIdException(
        'No such signedprekeyrecord! $signedPreKeyId',
      );
    }
    return SignedPreKeyRecord.fromSerialized(
      _decodeRecord(b64, 'Signal signed prekey'),
    );
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    final records = <SignedPreKeyRecord>[];
    for (final key in _prefs.getKeys().where(
      (candidate) => candidate.startsWith(_signedPreKeyPrefix),
    )) {
      final encoded = await _encrypted.read(key);
      if (encoded != null) {
        records.add(
          SignedPreKeyRecord.fromSerialized(
            _decodeRecord(encoded, 'Signal signed prekey'),
          ),
        );
      }
    }
    return records;
  }

  @override
  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) async {
    await _encrypted.write(
      '$_signedPreKeyPrefix$signedPreKeyId',
      base64Encode(record.serialize()),
    );
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async =>
      _encrypted.contains('$_signedPreKeyPrefix$signedPreKeyId');

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async =>
      _removeStored('$_signedPreKeyPrefix$signedPreKeyId');

  // --- SessionStore ---

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    final b64 = await _encrypted.read(_sessionKey(address));
    if (b64 == null) return SessionRecord();
    return SessionRecord.fromSerialized(
      decodeBase64Bounded(
        b64,
        minimumBytes: 1,
        maximumBytes: 4 * 1024 * 1024,
        field: 'Signal session',
        maxEncodedCharacters: 6 * 1024 * 1024,
      ),
    );
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    final prefix = '$_sessionPrefix$name::';
    return [
      for (final key in _prefs.getKeys().where((k) => k.startsWith(prefix)))
        if (int.tryParse(key.substring(prefix.length)) case final deviceId?
            when deviceId != 1)
          deviceId,
    ];
  }

  @override
  Future<void> storeSession(
    SignalProtocolAddress address,
    SessionRecord record,
  ) async {
    await _encrypted.write(
      _sessionKey(address),
      base64Encode(record.serialize()),
    );
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async =>
      _encrypted.contains(_sessionKey(address));

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async =>
      _removeStored(_sessionKey(address));

  @override
  Future<void> deleteAllSessions(String name) async {
    final prefix = '$_sessionPrefix$name::';
    for (final key
        in _prefs.getKeys().where((k) => k.startsWith(prefix)).toList()) {
      await _removeStored(key);
    }
  }

  Future<void> _removeStored(String key) async {
    if (_prefs.containsKey(key) && !await _prefs.remove(key)) {
      throw StateError('Unable to remove Signal protocol state');
    }
  }

  static Uint8List _decodeRecord(String encoded, String field) =>
      decodeBase64Bounded(
        encoded,
        minimumBytes: 1,
        maximumBytes: 64 * 1024,
        field: field,
        maxEncodedCharacters: 128 * 1024,
      );
}
