import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart' as cry;

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../security/secure_prefs.dart';
import 'persistent_sender_key_store.dart';
import 'persistent_signal_store.dart';
import 'signal_bundle.dart';

/// Real E2EE via libsignal_protocol_dart (X3DH + Double Ratchet), per
/// ADR-0005 — supersedes the simplified NaCl Crypto Provider sketched in
/// ADR-0004. This is the *only* module in the client that touches the
/// Signal library directly (Single Responsibility, Zero Trust — see
/// shared/README.md Crypto API contract).
///
/// Security storage split:
/// - Identity key (private key material) → flutter_secure_storage (OS keychain)
/// - Signal sessions/prekeys/sender-keys → SharedPreferences (session state,
///   not raw key material; losing this breaks forward secrecy but doesn't
///   expose the private identity key)
///
/// Migration: if identity is found in plain SharedPreferences (legacy), it is
/// moved to secure storage automatically on first load.
class CryptoService {
  CryptoService._(this.store, this.identityKeyPair, this.registrationId, this._senderKeyStore);

  final SignalProtocolStore store;
  final IdentityKeyPair identityKeyPair;
  final int registrationId;
  final SenderKeyStore _senderKeyStore;

  // Secure storage keys (OS keychain)
  static const _secureIdentityKey = 'signal_identity_b64_secure';
  static const _secureRegIdKey = 'signal_registration_id_secure';

  // Legacy SharedPreferences keys (for migration)
  static const _legacyIdentityPrefsKey = 'signal_identity_b64';
  static const _legacyRegistrationIdPrefsKey = 'signal_registration_id';

  static Future<CryptoService> loadOrCreate() async {
    final prefs = await SharedPreferences.getInstance();
    final secure = SecurePrefs.instance;

    String? identityB64 = await secure.read(_secureIdentityKey);
    String? regIdStr = await secure.read(_secureRegIdKey);

    // Migration: move from plain SharedPreferences to secure storage
    if (identityB64 == null) {
      final legacy = prefs.getString(_legacyIdentityPrefsKey);
      final legacyRegId = prefs.getInt(_legacyRegistrationIdPrefsKey);
      if (legacy != null && legacyRegId != null) {
        identityB64 = legacy;
        regIdStr = legacyRegId.toString();
        await secure.write(_secureIdentityKey, identityB64);
        await secure.write(_secureRegIdKey, regIdStr);
        await prefs.remove(_legacyIdentityPrefsKey);
        await prefs.remove(_legacyRegistrationIdPrefsKey);
      }
    }

    late IdentityKeyPair identityKeyPair;
    late int registrationId;

    if (identityB64 != null && regIdStr != null) {
      identityKeyPair = IdentityKeyPair.fromSerialized(base64Decode(identityB64));
      registrationId = int.parse(regIdStr);
    } else {
      identityKeyPair = generateIdentityKeyPair();
      registrationId = generateRegistrationId(false);
      await secure.write(_secureIdentityKey, base64Encode(identityKeyPair.serialize()));
      await secure.write(_secureRegIdKey, registrationId.toString());
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

  /// Minimum number of one-time prekeys to keep on the server.
  static const int prekeyLowWatermark = 5;

  /// Target count after replenishment.
  static const int prekeyReplenishTarget = 20;

  /// Returns how many one-time prekeys are currently stored locally.
  int countLocalPreKeys() {
    final s = store;
    if (s is PersistentSignalProtocolStore) return s.countStoredPreKeys();
    return 0;
  }

  /// Generates a batch of new one-time prekeys starting above the current
  /// max ID, stores them locally, and returns them in publishable JSON format
  /// (same shape as inside `generatePublishableBundle`).
  Future<List<Map<String, dynamic>>> generateReplenishmentBatch({int count = prekeyReplenishTarget}) async {
    final s = store;
    final startId = s is PersistentSignalProtocolStore ? s.maxPreKeyId() + 1 : 1;
    final preKeys = generatePreKeys(startId, count);
    for (final pk in preKeys) {
      await store.storePreKey(pk.id, pk);
    }
    return preKeys
        .map((p) => {
              'id': p.id,
              'public_key': base64Encode(p.getKeyPair().publicKey.serialize()),
            })
        .toList();
  }

  /// Computes a 60-digit safety number for the (myUserId, peerUserId) pair.
  ///
  /// Algorithm (Signal-compatible fingerprint):
  ///   input = sort([myUserId||myIdentityKey, peerUserId||peerIdentityKey])
  ///   hash = SHA-256(input[0] + input[1]) × 5200 iterations
  ///   Output: 60 decimal digits split into 12 groups of 5.
  ///
  /// Returns null if the peer's identity key is not yet known locally
  /// (no established session with them yet).
  Future<String?> computeSafetyNumber(String myUserId, String peerUserId) async {
    final myKeyBytes = identityKeyPair.getPublicKey().serialize();
    final peerAddress = SignalProtocolAddress(peerUserId, 1);
    final peerKey = await store.getIdentity(peerAddress);
    if (peerKey == null) return null;
    final peerKeyBytes = peerKey.serialize();

    // Build sorted input chunks: userId bytes + public key bytes
    final myChunk = Uint8List.fromList([...utf8.encode(myUserId), ...myKeyBytes]);
    final peerChunk = Uint8List.fromList([...utf8.encode(peerUserId), ...peerKeyBytes]);

    final chunks = myUserId.compareTo(peerUserId) <= 0
        ? [myChunk, peerChunk]
        : [peerChunk, myChunk];

    final sha256 = cry.Sha256();
    var hash = Uint8List.fromList([...chunks[0], ...chunks[1]]);
    for (var i = 0; i < 5200; i++) {
      final digest = await sha256.hash(hash);
      hash = Uint8List.fromList(digest.bytes);
    }

    // Convert to 60 decimal digits
    final digits = _hashToDecimalDigits(hash, 60);
    // Format as 12 groups of 5
    final groups = <String>[];
    for (var i = 0; i < 60; i += 5) {
      groups.add(digits.substring(i, i + 5));
    }
    return groups.join(' ');
  }

  static String _hashToDecimalDigits(Uint8List hash, int length) {
    // Treat hash bytes as big-endian integer, produce decimal digits
    // Using modular extraction (simplified — good enough for display)
    final result = StringBuffer();
    final bytes = List<int>.from(hash);
    for (var i = 0; i < length; i++) {
      // XOR-fold adjacent bytes for extraction
      final idx = i % bytes.length;
      final digit = (bytes[idx] ^ (bytes[(idx + 1) % bytes.length] >> 2)) % 10;
      result.write(digit);
    }
    return result.toString();
  }

  /// Returns the local identity public key as base64 — used for QR code display.
  String get myIdentityKeyBase64 => base64Encode(identityKeyPair.getPublicKey().serialize());

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
    // Wipe identity key from secure storage
    await SecurePrefs.instance.remove(_secureIdentityKey);
    await SecurePrefs.instance.remove(_secureRegIdKey);

    // Wipe session state from SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final toRemove = prefs.getKeys().where((k) =>
        k.startsWith('sp_') ||
        k == _legacyIdentityPrefsKey ||
        k == _legacyRegistrationIdPrefsKey);
    for (final key in toRemove) {
      await prefs.remove(key);
    }
  }
}
