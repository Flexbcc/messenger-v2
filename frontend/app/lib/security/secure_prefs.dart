import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/debug_log.dart';

/// Sensitive values backed by platform secure storage.
///
/// macOS: never use access-group without Keychain Sharing entitlements — that
/// triggers the Login password dialog. Legacy Keychain values may be migrated
/// secure-to-secure; plaintext preference remnants are deleted, never trusted.
class SecurePrefs {
  SecurePrefs._();
  static final instance = SecurePrefs._();

  /// Keychain items must always have a service namespace. Without one,
  /// unrelated Messenger builds installed for QA can resolve the same generic
  /// password records by account key alone.
  static const _storageNamespace = String.fromEnvironment(
    'SECURE_STORAGE_NAMESPACE',
    defaultValue: 'com.messenger.messengerApp',
  );
  static const _primaryStorageNamespace = 'com.messenger.messengerApp';

  /// SharedPreferences is keyed by bundle id, while Keychain is keyed by
  /// [_storageNamespace]. QA builds that override only the Keychain service
  /// must scope preferences belonging to the same cryptographic identity.
  static String scopedPreferenceKey(String key) =>
      _storageNamespace == _primaryStorageNamespace
      ? key
      : '$_storageNamespace::$key';

  static String get preferenceScopePrefix =>
      _storageNamespace == _primaryStorageNamespace
      ? ''
      : '$_storageNamespace::';

  static bool get _isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    mOptions: MacOsOptions(
      accountName: _storageNamespace,
      useDataProtectionKeyChain: false,
    ),
  );

  /// Releases before the namespace fix wrote generic-password records without
  /// a service. Only the primary production namespace may migrate those
  /// records; QA/flavoured builds must never import another build's secrets.
  static const _unscopedMacStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );

  /// Pre-fix keys were written with this groupId (caused password prompts).
  static const _legacyMacStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    mOptions: MacOsOptions(
      groupId: 'com.messenger.messengerApp',
      useDataProtectionKeyChain: false,
    ),
  );

  Future<String?> read(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final fallbackKey = 'secure_fallback::$key';

    // 1) Current Keychain (no group)
    final fromKeychain = await _readCanonical(key);
    if (fromKeychain != null) {
      await _removePreference(prefs, fallbackKey);
      await _removePreference(prefs, key);
      return fromKeychain;
    }

    // 2) One-time migration from the formerly unscoped Keychain query. A QA
    // build deliberately skips this branch to preserve account isolation.
    if (_isMacOS && _storageNamespace == _primaryStorageNamespace) {
      final unscoped = await _tryRead(_unscopedMacStorage, key);
      if (unscoped != null) {
        if (await _tryWrite(_storage, key, unscoped)) {
          await _unscopedMacStorage.delete(key: key);
          await _removePreference(prefs, fallbackKey);
          return unscoped;
        }
        throw StateError('Unable to migrate unscoped Keychain value');
      }
    }

    // 3) Legacy group Keychain — recover pre-break keys (may prompt once).
    // As above, only the primary app is allowed to import it.
    if (_isMacOS && _storageNamespace == _primaryStorageNamespace) {
      final legacy = await _tryRead(_legacyMacStorage, key);
      if (legacy != null) {
        if (await _tryWrite(_storage, key, legacy)) {
          try {
            await _legacyMacStorage.delete(key: key);
          } catch (_) {
            throw StateError('Unable to remove migrated legacy Keychain value');
          }
          await _removePreference(prefs, fallbackKey);
          return legacy;
        }
        throw StateError('Unable to migrate legacy Keychain value');
      }
    }

    // Former releases could place secrets in ordinary preferences. They are
    // untrusted input and must never be promoted back into secure storage.
    await _removePreference(prefs, fallbackKey);
    await _removePreference(prefs, key);
    return null;
  }

  Future<String?> _readCanonical(String key) async {
    try {
      final value = await _storage.read(key: key);
      if (value != null && value.isNotEmpty) return value;
      return null;
    } catch (error) {
      DebugLog.instance.warn('secure-storage', 'canonical read unavailable');
      throw StateError('Platform secure storage is unavailable');
    }
  }

  /// Legacy storage is migration-only. Its access group may legitimately be
  /// unavailable after entitlement removal, so failure here means "skip the
  /// old location", never "the canonical secret is absent".
  Future<String?> _tryRead(FlutterSecureStorage storage, String key) async {
    try {
      final value = await storage.read(key: key);
      if (value != null && value.isNotEmpty) return value;
    } catch (_) {
      DebugLog.instance.warn('secure-storage', 'legacy read unavailable');
    }
    return null;
  }

  Future<void> write(String key, String value) async {
    if (!await _tryWrite(_storage, key, value)) {
      throw StateError('Platform secure storage is unavailable');
    }
    final prefs = await SharedPreferences.getInstance();
    await _removePreference(prefs, 'secure_fallback::$key');
    await _removePreference(prefs, key);
  }

  /// Replaces a related credential pair and restores the previous pair if the
  /// second platform write fails. This is the closest available transaction
  /// boundary for Keychain/Keystore-backed values.
  Future<void> replacePair({
    required String firstKey,
    required String firstValue,
    required String secondKey,
    required String secondValue,
  }) async {
    final oldFirst = await read(firstKey);
    final oldSecond = await read(secondKey);
    try {
      await write(firstKey, firstValue);
      await write(secondKey, secondValue);
    } catch (writeError, writeStack) {
      try {
        if (oldFirst == null) {
          await remove(firstKey);
        } else {
          await write(firstKey, oldFirst);
        }
        if (oldSecond == null) {
          await remove(secondKey);
        } else {
          await write(secondKey, oldSecond);
        }
      } catch (_) {
        throw StateError('Secure credential update and rollback both failed');
      }
      Error.throwWithStackTrace(writeError, writeStack);
    }
  }

  Future<bool> _tryWrite(
    FlutterSecureStorage storage,
    String key,
    String value,
  ) async {
    try {
      await storage.write(key: key, value: value);
      return true;
    } catch (_) {
      DebugLog.instance.warn('secure-storage', 'canonical write unavailable');
      return false;
    }
  }

  Future<void> _removePreference(SharedPreferences prefs, String key) async {
    if (prefs.containsKey(key) && !await prefs.remove(key)) {
      throw StateError('Unable to remove legacy plaintext secret');
    }
  }

  Future<void> remove(String key) async {
    Object? secureDeleteError;
    try {
      await _storage.delete(key: key);
    } catch (error) {
      secureDeleteError = error;
      DebugLog.instance.warn('secure-storage', 'canonical delete unavailable');
    }
    if (_isMacOS) {
      try {
        await _legacyMacStorage.delete(key: key);
      } catch (_) {
        // The old access group may be unavailable after entitlement removal.
        // Canonical storage deletion above is the security boundary.
        DebugLog.instance.warn(
          'secure-storage',
          'legacy Keychain cleanup unavailable',
        );
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await _removePreference(prefs, 'secure_fallback::$key');
    await _removePreference(prefs, key);
    if (secureDeleteError != null) {
      throw StateError('Unable to delete value from platform secure storage');
    }
  }

  Future<bool> containsKey(String key) async {
    return await read(key) != null;
  }

  Future<void> clearKeys(Iterable<String> keys) async {
    Object? firstError;
    for (final key in keys) {
      try {
        await remove(key);
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) {
      throw StateError('One or more secure values could not be deleted');
    }
  }
}
