import 'dart:convert';

import '../security/crypto_encoding.dart';
import '../utils/user_id.dart';
import 'contact_pairing_payload.dart';
import 'local_settings_store.dart';

typedef PinnedContactIdentity = ({String deviceId, String identityKey});

/// Account-scoped cache of public key material learned from a verified QR.
class ContactPairingStore {
  ContactPairingStore({LocalSettingsStore? store})
    : _store = store ?? LocalSettingsStore();

  final LocalSettingsStore _store;

  static String _key(String userId) => 'contact_pairing.$userId';

  Future<void> save(
    ContactPairingPayload payload, {
    required String deviceId,
  }) async {
    if (!isValidUserIdFormat(payload.userId) ||
        deviceId.isEmpty ||
        deviceId.length > 64 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(deviceId)) {
      throw const FormatException('Invalid contact pairing identity');
    }
    await _store.setString(
      _key(payload.userId),
      jsonEncode({
        'device_id': deviceId,
        'auth_key': payload.authPublicKey,
        'identity_key': payload.identityPublicKey,
        'nonce': payload.nonce,
        'expires_at': payload.expiresAt.toUtc().toIso8601String(),
      }),
    );
  }

  Future<Map<String, dynamic>?> load(String userId) async {
    if (!isValidUserIdFormat(userId)) {
      throw const FormatException('Invalid contact pairing user id');
    }
    final raw = await _store.getString(_key(userId), '');
    if (raw.isEmpty) return null;
    if (raw.length > 2048) {
      throw const FormatException('Stored contact pairing is too large');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Stored contact pairing is invalid');
    }
    return decoded;
  }

  Future<PinnedContactIdentity?> pinnedIdentity(String userId) async {
    final value = await load(userId);
    if (value == null) return null;
    final deviceId = value['device_id'];
    final key = value['identity_key'];
    if (deviceId is! String ||
        deviceId.isEmpty ||
        deviceId.length > 64 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(deviceId) ||
        key is! String) {
      throw const FormatException('Stored contact identity key is invalid');
    }
    decodeBase64Exact(
      key,
      expectedBytes: 33,
      field: 'stored contact identity key',
      maxEncodedCharacters: 128,
    );
    return (deviceId: deviceId, identityKey: key);
  }
}
