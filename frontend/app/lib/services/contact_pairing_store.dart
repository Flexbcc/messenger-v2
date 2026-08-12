import 'dart:convert';

import 'contact_pairing_payload.dart';
import 'local_settings_store.dart';

/// Account-scoped cache of public key material learned from a verified QR.
class ContactPairingStore {
  ContactPairingStore({LocalSettingsStore? store})
    : _store = store ?? LocalSettingsStore();

  final LocalSettingsStore _store;

  static String _key(String userId) => 'contact_pairing.$userId';

  Future<void> save(ContactPairingPayload payload) => _store.setString(
    _key(payload.userId),
    jsonEncode({
      'auth_key': payload.authPublicKey,
      'identity_key': payload.identityPublicKey,
      'nonce': payload.nonce,
      'expires_at': payload.expiresAt.toUtc().toIso8601String(),
    }),
  );

  Future<Map<String, dynamic>?> load(String userId) async {
    final raw = await _store.getString(_key(userId), '');
    if (raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  }
}
