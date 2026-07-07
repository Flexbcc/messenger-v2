import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'persistent_sender_key_store.dart';
import 'persistent_signal_store.dart';
import 'signal_bundle.dart';

/// Real E2EE via libsignal_protocol_dart (X3DH + Double Ratchet), per
/// ADR-0005 — supersedes the simplified NaCl Crypto Provider sketched in
/// ADR-0004. This is the *only* module in the client that touches the
/// Signal library directly (Single Responsibility, Zero Trust — see
/// shared/README.md Crypto API contract).
///
/// MVP limitations, documented rather than hidden:
/// - Delivery/addressing is per-user, not per-Device (fixed deviceId=1).
/// - Sessions/prekeys/signed prekey persist across restarts via
///   `PersistentSignalProtocolStore` (SharedPreferences-backed, same
///   "not OS-keychain-grade" posture as identity storage below) — a page
///   refresh no longer loses them. `CryptoService.ephemeral()` (tests only)
///   still uses `InMemorySignalProtocolStore`, matching real "different
///   devices never share storage" semantics within one test process.
/// - Group encryption uses libsignal's sender-key primitives per
///   0301_GROUP_MESSAGING.md, persisted the same way
///   (`PersistentSenderKeyStore`).
class CryptoService {
  CryptoService._(this.store, this.identityKeyPair, this.registrationId, this._senderKeyStore);

  final SignalProtocolStore store;
  final IdentityKeyPair identityKeyPair;
  final int registrationId;
  final SenderKeyStore _senderKeyStore;

  static const _identityPrefsKey = 'signal_identity_b64';
  static const _registrationIdPrefsKey = 'signal_registration_id';

  static Future<CryptoService> loadOrCreate() async {
    final prefs = await SharedPreferences.getInstance();
    final existingIdentity = prefs.getString(_identityPrefsKey);
    final existingRegId = prefs.getInt(_registrationIdPrefsKey);

    late IdentityKeyPair identityKeyPair;
    late int registrationId;

    if (existingIdentity != null && existingRegId != null) {
      identityKeyPair = IdentityKeyPair.fromSerialized(base64Decode(existingIdentity));
      registrationId = existingRegId;
    } else {
      identityKeyPair = generateIdentityKeyPair();
      registrationId = generateRegistrationId(false);
      await prefs.setString(_identityPrefsKey, base64Encode(identityKeyPair.serialize()));
      await prefs.setInt(_registrationIdPrefsKey, registrationId);
    }

    final store = PersistentSignalProtocolStore(prefs, identityKeyPair, registrationId);
    final senderKeyStore = PersistentSenderKeyStore(prefs);
    return CryptoService._(store, identityKeyPair, registrationId, senderKeyStore);
  }

  /// Non-persisted instance for tests — see test/crypto_roundtrip_test.dart.
  /// Avoids sharing SharedPreferences-backed identity across simulated
  /// "different devices" within a single test process.
  factory CryptoService.ephemeral() {
    final identityKeyPair = generateIdentityKeyPair();
    final registrationId = generateRegistrationId(false);
    final store = InMemorySignalProtocolStore(identityKeyPair, registrationId);
    return CryptoService._(store, identityKeyPair, registrationId, InMemorySenderKeyStore());
  }

  /// Generates a fresh signed prekey + batch of one-time prekeys, stores the
  /// private halves locally, and returns the publishable JSON bundle to send
  /// to Home Node at registration (see shared/README.md).
  Future<Map<String, dynamic>> generatePublishableBundle({int preKeyCount = 20}) async {
    final signedPreKey = generateSignedPreKey(identityKeyPair, 1);
    await store.storeSignedPreKey(signedPreKey.id, signedPreKey);

    final preKeys = generatePreKeys(1, preKeyCount);
    for (final pk in preKeys) {
      await store.storePreKey(pk.id, pk);
    }

    return SignalBundle.toPublishableJson(
      identityKeyPair: identityKeyPair,
      registrationId: registrationId,
      signedPreKey: signedPreKey,
      preKeys: preKeys,
    );
  }

  Future<bool> hasSessionWith(String userId) =>
      store.containsSession(SignalProtocolAddress(userId, 1));

  Future<void> establishSessionFromBundle(String userId, Map<String, dynamic> bundleJson) async {
    final address = SignalProtocolAddress(userId, 1);
    final bundle = SignalBundle.fromJson(bundleJson);
    await SessionBuilder.fromSignalStore(store, address).processPreKeyBundle(bundle);
  }

  /// Returns the envelope `ciphertext` string: a small JSON tag + base64
  /// body, opaque to the server (see shared/README.md Message Envelope).
  Future<String> encrypt(String recipientUserId, Uint8List plaintext) async {
    final address = SignalProtocolAddress(recipientUserId, 1);
    final cipher = SessionCipher.fromStore(store, address);
    final message = await cipher.encrypt(plaintext);
    return jsonEncode({
      't': message.getType(),
      'b': base64Encode(message.serialize()),
    });
  }

  Future<Uint8List> decrypt(String senderUserId, String ciphertextField) async {
    final address = SignalProtocolAddress(senderUserId, 1);
    final cipher = SessionCipher.fromStore(store, address);
    final decoded = jsonDecode(ciphertextField) as Map<String, dynamic>;
    final type = decoded['t'] as int;
    final body = base64Decode(decoded['b'] as String);

    if (type == CiphertextMessage.prekeyType) {
      return cipher.decrypt(PreKeySignalMessage(body));
    } else {
      return cipher.decryptFromSignal(SignalMessage.fromSerialized(body));
    }
  }

  // --- Group (sender-key) crypto — see 0301_GROUP_MESSAGING.md ---

  SenderKeyName _senderKeyName(String groupId, String senderUserId) =>
      SenderKeyName(groupId, SignalProtocolAddress(senderUserId, 1));

  /// Creates (or returns the existing) sender key for [groupId] under my own
  /// identity, serialized for pairwise distribution to other members.
  Future<String> createGroupSenderKeyDistribution(String groupId, String myUserId) async {
    final message = await GroupSessionBuilder(_senderKeyStore).create(_senderKeyName(groupId, myUserId));
    return base64Encode(message.serialize());
  }

  /// Processes a sender key distribution received (pairwise-decrypted) from
  /// [senderUserId] for [groupId] — after this, decryptGroup() works for
  /// that sender's messages in that group.
  Future<void> processGroupSenderKeyDistribution(String groupId, String senderUserId, String distributionB64) async {
    final wrapper = SenderKeyDistributionMessageWrapper.fromSerialized(base64Decode(distributionB64));
    await GroupSessionBuilder(_senderKeyStore).process(_senderKeyName(groupId, senderUserId), wrapper);
  }

  Future<String> encryptGroup(String groupId, String myUserId, Uint8List plaintext) async {
    final ciphertext = await GroupCipher(_senderKeyStore, _senderKeyName(groupId, myUserId)).encrypt(plaintext);
    return jsonEncode({'group': true, 'b': base64Encode(ciphertext)});
  }

  Future<Uint8List> decryptGroup(String groupId, String senderUserId, String ciphertextField) async {
    final decoded = jsonDecode(ciphertextField) as Map<String, dynamic>;
    final body = base64Decode(decoded['b'] as String);
    return GroupCipher(_senderKeyStore, _senderKeyName(groupId, senderUserId)).decrypt(body);
  }

  /// Removes all locally persisted Signal state — used by Emergency Lock (critical).
  static Future<void> wipeLocalKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final toRemove = prefs.getKeys().where((k) =>
        k.startsWith('sp_') ||
        k == _identityPrefsKey ||
        k == _registrationIdPrefsKey);
    for (final key in toRemove) {
      await prefs.remove(key);
    }
  }
}
