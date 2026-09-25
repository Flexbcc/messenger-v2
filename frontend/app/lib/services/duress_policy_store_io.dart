import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/duress_policy.dart';
import '../security/pin_security.dart';
import 'account_scoped_file_name.dart';
import 'atomic_private_file_io.dart';
import 'pin_encrypted_json.dart';

/// PIN-encrypted duress policy — spec/0404 `duress_policy.v1`.
class DuressPolicyStore {
  DuressPolicyStore._();
  static final instance = DuressPolicyStore._();

  static const _fileName = 'duress_policy.v1';

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/${accountScopedFileName(_fileName)}');
  }

  Future<File> _legacyFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/${legacyAccountScopedFileName(_fileName)}');
  }

  Future<DuressPolicyData?> load(String pin) async {
    final currentFile = await _file();
    final legacyFile = await _legacyFile();
    final usingLegacy =
        !await AtomicPrivateFile.existsRegular(currentFile) &&
        await AtomicPrivateFile.existsRegular(legacyFile);
    final file = usingLegacy ? legacyFile : currentFile;
    final exists = await AtomicPrivateFile.existsRegular(file);
    final salt = await PinSecurity.realPinSalt();
    if (salt == null) {
      if (exists) {
        throw StateError('Duress policy exists without a configured PIN');
      }
      return null;
    }
    if (!exists) return null;

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
    final data = DuressPolicyData.fromJson(json);
    if (usingLegacy) {
      await save(pin, data);
      await AtomicPrivateFile.delete(legacyFile);
    }
    return data;
  }

  Future<void> save(String pin, DuressPolicyData data) async {
    final salt = await PinSecurity.realPinSalt();
    if (salt == null) {
      throw StateError('Cannot save duress policy without a configured PIN');
    }

    final packed = await PinEncryptedJson.encryptMap(
      value: data.toJson(),
      pin: pin,
      salt: salt,
    );
    final file = await _file();
    await AtomicPrivateFile.writeString(file, packed);
  }

  Future<void> wipe() async {
    final files = [await _file(), await _legacyFile()];
    for (final file in files) {
      await AtomicPrivateFile.delete(file);
    }
  }
}
