import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'persistent_sender_key_store.dart';
import 'persistent_signal_store.dart';
import 'signal_bundle.dart';
import '../security/crypto_encoding.dart';
import '../security/secure_prefs.dart';

/// Real E2EE via libsignal_protocol_dart (X3DH + Double Ratchet), per
/// ADR-0005 — supersedes the simplified NaCl Crypto Provider sketched in
/// ADR-0004. This is the *only* module in the client that touches the
/// Signal library directly (Single Responsibility, Zero Trust — see
/// shared/README.md Crypto API contract).
///
/// MVP limitations, documented rather than hidden:
/// - Delivery/addressing is per-user, not per-Device (fixed deviceId=1).
/// - Sessions/prekeys/signed prekey persist encrypted across restarts via
///   `PersistentSignalProtocolStore` — a page
///   refresh no longer loses them. `CryptoService.ephemeral()` (tests only)
///   still uses `InMemorySignalProtocolStore`, matching real "different
///   devices never share storage" semantics within one test process.
/// - Group encryption uses libsignal's sender-key primitives per
///   0301_GROUP_MESSAGING.md, persisted the same way
///   (`PersistentSenderKeyStore`).
class CryptoService {
  CryptoService._(
    this.store,
    this.identityKeyPair,
    this.registrationId,
    this._senderKeyStore,
  );

  final SignalProtocolStore store;
  final IdentityKeyPair identityKeyPair;
  final int registrationId;
  final SenderKeyStore _senderKeyStore;
  static const _maxCiphertextCharacters = 192 * 1024;
  static const _maxCiphertextBytes = 144 * 1024;

  /// The stable public identity of this device. Reading it must never rotate
  /// signed/one-time prekeys: already queued PreKey messages still need their
  /// matching private keys after a reload.
  String get identityPublicKeyBase64 =>
      base64Encode(identityKeyPair.getPublicKey().serialize());

  static const _identityPrefsKey = 'signal_identity_b64';
  static const _registrationIdPrefsKey = 'signal_registration_id';

  SignalProtocolAddress _address(String userId, [String? deviceId]) =>
      SignalProtocolAddress(
        deviceId == null || deviceId.isEmpty ? userId : '$userId::$deviceId',
        1,
      );

  static Future<CryptoService> loadOrCreate() async {
    final prefs = await SharedPreferences.getInstance();
    final existingIdentity = await SecurePrefs.instance.read(_identityPrefsKey);
    final existingRegId = prefs.getInt(_registrationIdPrefsKey);

    late IdentityKeyPair identityKeyPair;
    late int registrationId;

    if (existingIdentity == null && existingRegId == null) {
      identityKeyPair = generateIdentityKeyPair();
      registrationId = generateRegistrationId(false);
      await SecurePrefs.instance.write(
        _identityPrefsKey,
        base64Encode(identityKeyPair.serialize()),
      );
      if (!await prefs.setInt(_registrationIdPrefsKey, registrationId)) {
        await SecurePrefs.instance.remove(_identityPrefsKey);
        throw StateError('Не удалось сохранить Signal registration id');
      }
    } else if (existingIdentity != null && existingRegId != null) {
      identityKeyPair = IdentityKeyPair.fromSerialized(
        _decodeIdentity(existingIdentity),
      );
      if (existingRegId <= 0 || existingRegId > 16380) {
        throw StateError('Сохранённый Signal registration id повреждён');
      }
      registrationId = existingRegId;
    } else {
      throw StateError(
        'Локальная Signal-идентичность сохранена не полностью; '
        'автоматическая ротация запрещена',
      );
    }

    final store = PersistentSignalProtocolStore(
      prefs,
      identityKeyPair,
      registrationId,
    );
    final senderKeyStore = PersistentSenderKeyStore(prefs);
    return CryptoService._(
      store,
      identityKeyPair,
      registrationId,
      senderKeyStore,
    );
  }

  /// Non-persisted instance for tests — see test/crypto_roundtrip_test.dart.
  /// Avoids sharing SharedPreferences-backed identity across simulated
  /// "different devices" within a single test process.
  factory CryptoService.ephemeral() {
    final identityKeyPair = generateIdentityKeyPair();
    final registrationId = generateRegistrationId(false);
    final store = InMemorySignalProtocolStore(identityKeyPair, registrationId);
    return CryptoService._(
      store,
      identityKeyPair,
      registrationId,
      InMemorySenderKeyStore(),
    );
  }

  /// Generates a fresh signed prekey + batch of one-time prekeys, stores the
  /// private halves locally, and returns the publishable JSON bundle to send
  /// to Home Node at registration (see shared/README.md).
  Future<Map<String, dynamic>> generatePublishableBundle({
    int preKeyCount = 20,
  }) async {
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

  Future<bool> hasSessionWith(String userId, {String? deviceId}) =>
      store.containsSession(_address(userId, deviceId));

  Future<void> establishSessionFromBundle(
    String userId,
    Map<String, dynamic> bundleJson, {
    String? deviceId,
  }) async {
    final address = _address(userId, deviceId);
    final bundle = SignalBundle.fromJson(bundleJson);
    await SessionBuilder.fromSignalStore(
      store,
      address,
    ).processPreKeyBundle(bundle);
  }

  /// Returns the envelope `ciphertext` string: a small JSON tag + base64
  /// body, opaque to the server (see shared/README.md Message Envelope).
  Future<String> encrypt(
    String recipientUserId,
    Uint8List plaintext, {
    String? recipientDeviceId,
  }) async {
    final address = _address(recipientUserId, recipientDeviceId);
    final cipher = SessionCipher.fromStore(store, address);
    final message = await cipher.encrypt(plaintext);
    return jsonEncode({
      't': message.getType(),
      'b': base64Encode(message.serialize()),
    });
  }

  Future<Uint8List> decrypt(
    String senderUserId,
    String ciphertextField, {
    String? senderDeviceId,
  }) async {
    final address = _address(senderUserId, senderDeviceId);
    final cipher = SessionCipher.fromStore(store, address);
    final decoded = _decodeCiphertextEnvelope(ciphertextField, group: false);
    final type = decoded.type!;
    final body = decoded.body;

    if (type == CiphertextMessage.prekeyType) {
      return cipher.decrypt(PreKeySignalMessage(body));
    }
    if (type == CiphertextMessage.whisperType) {
      return cipher.decryptFromSignal(SignalMessage.fromSerialized(body));
    }
    throw const FormatException('Unsupported Signal ciphertext type');
  }

  // --- Group (sender-key) crypto — see 0301_GROUP_MESSAGING.md ---

  SenderKeyName _senderKeyName(String groupId, String senderUserId) =>
      SenderKeyName(groupId, SignalProtocolAddress(senderUserId, 1));

  /// Creates (or returns the existing) sender key for [groupId] under my own
  /// identity, serialized for pairwise distribution to other members.
  Future<String> createGroupSenderKeyDistribution(
    String groupId,
    String myUserId,
  ) async {
    final message = await GroupSessionBuilder(
      _senderKeyStore,
    ).create(_senderKeyName(groupId, myUserId));
    return base64Encode(message.serialize());
  }

  /// Processes a sender key distribution received (pairwise-decrypted) from
  /// [senderUserId] for [groupId] — after this, decryptGroup() works for
  /// that sender's messages in that group.
  Future<void> processGroupSenderKeyDistribution(
    String groupId,
    String senderUserId,
    String distributionB64,
  ) async {
    if (distributionB64.isEmpty ||
        distributionB64.length > _maxCiphertextCharacters ||
        !RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(distributionB64)) {
      throw const FormatException('Invalid sender-key distribution');
    }
    final distribution = base64Decode(distributionB64);
    if (distribution.isEmpty || distribution.length > _maxCiphertextBytes) {
      throw const FormatException('Invalid sender-key distribution size');
    }
    final wrapper = SenderKeyDistributionMessageWrapper.fromSerialized(
      distribution,
    );
    await GroupSessionBuilder(
      _senderKeyStore,
    ).process(_senderKeyName(groupId, senderUserId), wrapper);
  }

  Future<String> encryptGroup(
    String groupId,
    String myUserId,
    Uint8List plaintext,
  ) async {
    final ciphertext = await GroupCipher(
      _senderKeyStore,
      _senderKeyName(groupId, myUserId),
    ).encrypt(plaintext);
    return jsonEncode({'group': true, 'b': base64Encode(ciphertext)});
  }

  Future<Uint8List> decryptGroup(
    String groupId,
    String senderUserId,
    String ciphertextField,
  ) async {
    final body = _decodeCiphertextEnvelope(ciphertextField, group: true).body;
    return GroupCipher(
      _senderKeyStore,
      _senderKeyName(groupId, senderUserId),
    ).decrypt(body);
  }

  static ({int? type, Uint8List body}) _decodeCiphertextEnvelope(
    String encoded, {
    required bool group,
  }) {
    if (encoded.isEmpty || encoded.length > _maxCiphertextCharacters) {
      throw const FormatException('Ciphertext envelope has an invalid size');
    }
    final raw = jsonDecode(encoded);
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Ciphertext envelope must be an object');
    }
    final allowedKeys = group ? const {'group', 'b'} : const {'t', 'b'};
    if (raw.length != allowedKeys.length ||
        raw.keys.any((key) => !allowedKeys.contains(key))) {
      throw const FormatException('Ciphertext envelope fields are invalid');
    }
    if (group && raw['group'] != true) {
      throw const FormatException('Group ciphertext marker is invalid');
    }
    final type = group ? null : raw['t'];
    if (!group && type is! int) {
      throw const FormatException('Signal ciphertext type is invalid');
    }
    final bodyText = raw['b'];
    if (bodyText is! String ||
        bodyText.isEmpty ||
        bodyText.length > _maxCiphertextCharacters ||
        !RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(bodyText)) {
      throw const FormatException('Ciphertext body is invalid');
    }
    final body = base64Decode(bodyText);
    if (body.isEmpty || body.length > _maxCiphertextBytes) {
      throw const FormatException('Ciphertext body has an invalid size');
    }
    return (type: type as int?, body: body);
  }

  /// Removes all locally persisted Signal state — used by Emergency Lock (critical).
  static Future<void> wipeLocalKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final toRemove = prefs.getKeys().where(
      (k) =>
          k.startsWith('sp_') ||
          k == _identityPrefsKey ||
          k == _registrationIdPrefsKey,
    );
    for (final key in toRemove) {
      if (!await prefs.remove(key)) {
        throw StateError('Не удалось удалить Signal protocol state');
      }
    }
    await SecurePrefs.instance.remove(_identityPrefsKey);
  }

  static Future<Map<String, dynamic>> exportIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    final identity = await SecurePrefs.instance.read(_identityPrefsKey);
    final registrationId = prefs.getInt(_registrationIdPrefsKey);
    if (identity == null || registrationId == null) {
      throw StateError('Локальная Signal-идентичность не найдена');
    }
    final state = <String, dynamic>{};
    for (final key in prefs.getKeys().where((key) => key.startsWith('sp_'))) {
      final value = prefs.get(key);
      if (value is String ||
          value is int ||
          value is double ||
          value is bool ||
          value is List<String>) {
        state[key] = value;
      }
    }
    return {
      'identity_b64': identity,
      'registration_id': registrationId,
      'protocol_state': state,
    };
  }

  static Future<void> importIdentity(Map<String, dynamic> value) async {
    validateIdentityBackup(value);
    final identity = value['identity_b64'] as String?;
    final registrationId = value['registration_id'] as int?;
    final prefs = await SharedPreferences.getInstance();
    await SecurePrefs.instance.write(_identityPrefsKey, identity!);
    if (!await prefs.setInt(_registrationIdPrefsKey, registrationId!)) {
      throw StateError('Не удалось сохранить Signal registration id');
    }
    for (final key in prefs.getKeys().where((key) => key.startsWith('sp_'))) {
      if (!await prefs.remove(key)) {
        throw StateError('Не удалось заменить Signal protocol state');
      }
    }
    final state = value['protocol_state'];
    if (state is Map<String, dynamic>) {
      for (final entry in state.entries) {
        if (!entry.key.startsWith('sp_')) continue;
        final item = entry.value;
        var saved = false;
        if (item is String) saved = await prefs.setString(entry.key, item);
        if (item is int) saved = await prefs.setInt(entry.key, item);
        if (item is double) saved = await prefs.setDouble(entry.key, item);
        if (item is bool) saved = await prefs.setBool(entry.key, item);
        if (item is List) {
          saved = await prefs.setStringList(
            entry.key,
            item.map((e) => e.toString()).toList(),
          );
        }
        if (!saved) throw StateError('Не удалось сохранить Signal state');
      }
    }
  }

  static void validateIdentityBackup(Map<String, dynamic> value) {
    final identity = value['identity_b64'];
    final registrationId = value['registration_id'];
    if (identity is! String || registrationId is! int) {
      throw const FormatException('В копии отсутствует Signal-идентичность');
    }
    IdentityKeyPair.fromSerialized(_decodeIdentity(identity));
    if (registrationId <= 0 || registrationId > 16380) {
      throw const FormatException('Некорректный Signal registration id');
    }
    final state = value['protocol_state'];
    if (state != null && state is! Map<String, dynamic>) {
      throw const FormatException('Некорректный Signal protocol state');
    }
    if (state is Map<String, dynamic>) {
      if (state.length > 4096) {
        throw const FormatException('Signal protocol state слишком велик');
      }
      var totalCharacters = 0;
      for (final entry in state.entries) {
        if (!entry.key.startsWith('sp_') ||
            entry.key.length > 256 ||
            !RegExp(r'^[A-Za-z0-9_.:@-]+$').hasMatch(entry.key)) {
          throw const FormatException('Некорректный ключ Signal state');
        }
        final item = entry.value;
        final stringList =
            item is List && item.every((value) => value is String);
        final supported =
            item is String ||
            item is int ||
            item is double ||
            item is bool ||
            stringList;
        if (!supported) {
          throw const FormatException('Некорректное значение Signal state');
        }
        if (item is String) {
          if (item.length > 4 * 1024 * 1024) {
            throw const FormatException('Значение Signal state слишком велико');
          }
          totalCharacters += item.length;
        }
        if (item is List) {
          if (item.length > 4096 ||
              item.any(
                (value) => value is! String || value.length > 1024 * 1024,
              )) {
            throw const FormatException('Список Signal state слишком велик');
          }
          totalCharacters += item.fold<int>(
            0,
            (total, value) => total + (value as String).length,
          );
        }
        if (totalCharacters > 64 * 1024 * 1024) {
          throw const FormatException('Signal protocol state превышает лимит');
        }
      }
    }
  }

  static Uint8List _decodeIdentity(String encoded) => decodeBase64Bounded(
    encoded,
    minimumBytes: 64,
    maximumBytes: 256,
    field: 'Signal identity',
    maxEncodedCharacters: 384,
  );
}
