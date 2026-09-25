import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/hidden_chat.dart';
import '../security/pin_security.dart';
import 'account_scoped_file_name.dart';
import 'atomic_private_file_io.dart';
import 'pin_encrypted_json.dart';

/// Encrypted at-rest storage for hidden chats (AES-GCM, key from PIN) — native/desktop.
class HiddenVaultStore {
  HiddenVaultStore._();
  static final instance = HiddenVaultStore._();

  static const _fileName = 'hidden_vault.v1';

  Future<File> _vaultFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/${accountScopedFileName(_fileName)}');
  }

  Future<File> _legacyVaultFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/${legacyAccountScopedFileName(_fileName)}');
  }

  Future<HiddenVaultData?> load(String pin) async {
    final currentFile = await _vaultFile();
    final legacyFile = await _legacyVaultFile();
    final usingLegacy =
        !await AtomicPrivateFile.existsRegular(currentFile) &&
        await AtomicPrivateFile.existsRegular(legacyFile);
    final file = usingLegacy ? legacyFile : currentFile;
    final exists = await AtomicPrivateFile.existsRegular(file);
    final salt = await PinSecurity.realPinSalt();
    if (salt == null) {
      if (exists) {
        throw StateError('Hidden vault exists without a configured PIN');
      }
      return HiddenVaultData();
    }
    if (!exists) return HiddenVaultData();

    final packed = await AtomicPrivateFile.readString(
      file,
      maxBytes: PinEncryptedJson.maxPackedCharacters,
    );
    final json = await PinEncryptedJson.decryptMap(
      packed: packed!,
      pin: pin,
      salt: salt,
    );
    if (json == null) return null;
    final data = HiddenVaultData.fromJson(json);
    if (usingLegacy) {
      await save(pin, data);
      await AtomicPrivateFile.delete(legacyFile);
    }
    return data;
  }

  Future<void> save(String pin, HiddenVaultData data) async {
    final salt = await PinSecurity.realPinSalt();
    if (salt == null) {
      throw StateError('Cannot save hidden vault without a configured PIN');
    }

    final out = await PinEncryptedJson.encryptMap(
      value: data.toJson(),
      pin: pin,
      salt: salt,
    );
    final file = await _vaultFile();
    await AtomicPrivateFile.writeString(file, out);
  }

  Future<void> wipe() async {
    final files = [await _vaultFile(), await _legacyVaultFile()];
    for (final file in files) {
      await AtomicPrivateFile.delete(file);
    }
  }
}
