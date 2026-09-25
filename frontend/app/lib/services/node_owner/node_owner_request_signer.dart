import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../security/secure_prefs.dart';
import 'managed_node.dart';
import 'node_owner_key_store.dart';

class SignedOwnerRequest {
  const SignedOwnerRequest({required this.headerValue, required this.sequence});

  final String headerValue;
  final int sequence;
}

class NodeOwnerRequestSigner {
  NodeOwnerRequestSigner({
    NodeOwnerKeyStore? keyStore,
    SecurePrefs? securePrefs,
  }) : _keyStore = keyStore ?? NodeOwnerKeyStore(securePrefs: securePrefs),
       _securePrefs = securePrefs ?? SecurePrefs.instance;

  static const _domain = 'OUO/OWNER_REQUEST/v1\u0000';
  static final _random = Random.secure();
  final NodeOwnerKeyStore _keyStore;
  final SecurePrefs _securePrefs;
  Future<void> _sequenceQueue = Future.value();

  Future<SignedOwnerRequest> sign({
    required ManagedNode node,
    required String method,
    required String path,
    required List<int> body,
    DateTime? now,
  }) async {
    final sequence = await _reserveSequence(node.nodeId);
    final request = <String, dynamic>{
      'protocol_version': 'ouo-owner-request/1',
      'object_version': 1,
      'certificate_serial': node.certificateSerial,
      'timestamp': (now ?? DateTime.now()).toUtc().toIso8601String(),
      'nonce': base64UrlEncode(
        List<int>.generate(24, (_) => _random.nextInt(256)),
      ).replaceAll('=', ''),
      'sequence': sequence,
      'method': method.toUpperCase(),
      'path': path.startsWith('/') ? path : '/$path',
      'body_sha256': _sha256Hex(body),
      'signature_algorithm': 'Ed25519',
    };
    final signature = await _keyStore.sign(
      node.keyAlias,
      utf8.encode('$_domain${_canonicalJson(request)}'),
    );
    request['signature'] = signature;
    final encoded = base64UrlEncode(
      utf8.encode(_canonicalJson(request)),
    ).replaceAll('=', '');
    return SignedOwnerRequest(headerValue: encoded, sequence: sequence);
  }

  Future<int> _reserveSequence(String nodeId) async {
    final result = Completer<int>();
    _sequenceQueue = _sequenceQueue
        .then((_) async {
          final key = 'node_owner_sequence_v1::$nodeId';
          final current = int.tryParse(await _securePrefs.read(key) ?? '') ?? 0;
          await _securePrefs.write(key, (current + 1).toString());
          result.complete(current);
        })
        .catchError((Object error, StackTrace stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        });
    return result.future;
  }

  static String _canonicalJson(Map<String, dynamic> value) {
    final sorted = <String, dynamic>{};
    for (final key in value.keys.toList()..sort()) {
      sorted[key] = value[key];
    }
    return jsonEncode(sorted);
  }

  static String _sha256Hex(List<int> bytes) {
    return sha256.convert(bytes).toString();
  }
}
