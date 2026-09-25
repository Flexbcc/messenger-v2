import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import '../../security/crypto_encoding.dart';
import '../../security/secure_prefs.dart';

class NodeOwnerPublicKey {
  const NodeOwnerPublicKey({required this.keyAlias, required this.publicKey});

  final String keyAlias;
  final String publicKey;
}

/// Device keys are separate per managed node and never enter ordinary prefs.
///
/// The current portable backend stores Ed25519 seed material in OS secure
/// storage. Android Keystore / Secure Enclave non-exportable signing remains a
/// platform-specific follow-up and must not be claimed by this implementation.
class NodeOwnerKeyStore {
  NodeOwnerKeyStore({SecurePrefs? securePrefs})
    : _securePrefs = securePrefs ?? SecurePrefs.instance;

  static const _prefix = 'node_owner_ed25519_v1::';
  final SecurePrefs _securePrefs;
  final Ed25519 _ed25519 = Ed25519();

  Future<NodeOwnerPublicKey> createKey() async {
    final keyPair = await _ed25519.newKeyPair();
    final privateBytes = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    final alias = const Uuid().v4();
    await _securePrefs.write(
      '$_prefix$alias',
      jsonEncode({
        'private_key': base64UrlEncode(privateBytes),
        'public_key': base64UrlEncode(publicKey.bytes),
      }),
    );
    return NodeOwnerPublicKey(
      keyAlias: alias,
      publicKey: base64UrlEncode(publicKey.bytes),
    );
  }

  Future<String> sign(String keyAlias, List<int> message) async {
    final keyPair = await _readKeyPair(keyAlias);
    final signature = await _ed25519.sign(message, keyPair: keyPair);
    return base64UrlEncode(signature.bytes);
  }

  Future<void> remove(String keyAlias) =>
      _securePrefs.remove('$_prefix$keyAlias');

  Future<bool> contains(String keyAlias) =>
      _securePrefs.containsKey('$_prefix$keyAlias');

  Future<SimpleKeyPairData> _readKeyPair(String keyAlias) async {
    final raw = await _securePrefs.read('$_prefix$keyAlias');
    if (raw == null) throw StateError('Node owner key is unavailable');
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid node owner key record');
    }
    final privateBytes = decodeBase64Exact(
      decoded['private_key']?.toString() ?? '',
      expectedBytes: 32,
      field: 'node owner private key',
      urlSafe: true,
    );
    final publicBytes = decodeBase64Exact(
      decoded['public_key']?.toString() ?? '',
      expectedBytes: 32,
      field: 'node owner public key',
      urlSafe: true,
    );
    return SimpleKeyPairData(
      privateBytes,
      publicKey: SimplePublicKey(publicBytes, type: KeyPairType.ed25519),
      type: KeyPairType.ed25519,
    );
  }
}
