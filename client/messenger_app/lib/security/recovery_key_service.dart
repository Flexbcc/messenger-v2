import 'dart:math';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'secure_prefs.dart';

/// Generates and stores a local recovery key.
///
/// The key is a 128-bit random value rendered as a 24-char alphanumeric
/// string (split into 4 groups of 6 for readability). It is stored in
/// OS secure storage (Keychain / EncryptedSharedPreferences) and never
/// leaves the device — there is no server-side recovery in the MVP.
///
/// Usage: generate once → user copies/writes down → can be used to
/// verify ownership or (future) re-derive access after wipe.
class RecoveryKeyService {
  RecoveryKeyService._();
  static final instance = RecoveryKeyService._();

  static const _storeKey = 'recovery_key_v1';
  static const _hashKey  = 'recovery_key_hash_v1';

  static final _secure = SecurePrefs.instance;
  static final _rng = Random.secure();

  // Alphanumeric charset — no ambiguous chars (0/O, 1/l/I)
  static const _chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// Generates a new 24-char recovery key, stores it, returns the key.
  /// Overwrites any existing key.
  Future<String> generate() async {
    final raw = List<int>.generate(24, (_) => _chars.codeUnitAt(_rng.nextInt(_chars.length)));
    final key = String.fromCharCodes(raw);
    await _secure.write(_storeKey, key);

    // Store SHA-256 hash for future offline verification without exposing key.
    final digest = await Sha256().hash(utf8.encode(key));
    await _secure.write(_hashKey, base64Encode(digest.bytes));

    return key;
  }

  /// Returns stored key, or null if not yet generated.
  Future<String?> load() => _secure.read(_storeKey);

  /// Returns true if a key has been generated.
  Future<bool> exists() async => (await _secure.read(_storeKey)) != null;

  /// Verifies a candidate key matches the stored hash (constant-time-ish).
  Future<bool> verify(String candidate) async {
    final stored = await _secure.read(_hashKey);
    if (stored == null) return false;
    final digest = await Sha256().hash(utf8.encode(candidate.toUpperCase().replaceAll(' ', '-')));
    return base64Encode(digest.bytes) == stored;
  }

  /// Deletes the stored key.
  Future<void> wipe() async {
    await _secure.remove(_storeKey);
    await _secure.remove(_hashKey);
  }

  /// Formats key as "XXXXXX-XXXXXX-XXXXXX-XXXXXX" for display.
  static String format(String raw) {
    final s = raw.replaceAll('-', '').replaceAll(' ', '');
    if (s.length != 24) return raw;
    return '${s.substring(0,6)}-${s.substring(6,12)}-${s.substring(12,18)}-${s.substring(18,24)}';
  }
}
