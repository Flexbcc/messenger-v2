import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../crypto/auth_keypair.dart';
import '../security/crypto_encoding.dart';
import '../utils/user_id.dart';

/// Minimal signed QR handshake. It intentionally contains no profile fields.
/// Profile data is exchanged later over the established encrypted channel.
class ContactPairingPayload {
  const ContactPairingPayload({
    required this.userId,
    required this.authPublicKey,
    required this.identityPublicKey,
    required this.nonce,
    required this.expiresAt,
  });

  static const kind = 'ouo_contact_pair';
  static const version = 2;
  static const _maxPayloadCharacters = 4096;
  static const _maxTtl = Duration(minutes: 60);
  static const _clockSkew = Duration(minutes: 5);
  static const _allowedKeys = {
    'kind',
    'v',
    'user_id',
    'auth_key',
    'identity_key',
    'nonce',
    'expires_at',
    'signature',
  };

  final String userId;
  final String authPublicKey;
  final String identityPublicKey;
  final String nonce;
  final DateTime expiresAt;

  static Future<String> create({
    required String userId,
    required AuthKeyPair signer,
    required String identityPublicKey,
    required Duration ttl,
    DateTime? now,
  }) async {
    final issuedAt = (now ?? DateTime.now()).toUtc();
    if (ttl <= Duration.zero || ttl > _maxTtl) {
      throw const FormatException(
        'Срок действия QR должен быть от 1 до 60 минут',
      );
    }
    final normalizedUserId = normalizeUserId(userId);
    if (!isValidUserIdFormat(normalizedUserId)) {
      throw const FormatException('Некорректный идентификатор контакта');
    }
    decodeBase64Exact(
      identityPublicKey,
      expectedBytes: 33,
      field: 'identity_key',
      maxEncodedCharacters: 128,
    );
    final random = Random.secure();
    final body = <String, Object>{
      'kind': kind,
      'v': version,
      'user_id': normalizedUserId,
      'auth_key': signer.publicKeyBase64,
      'identity_key': identityPublicKey,
      'nonce': base64UrlEncode(
        List<int>.generate(24, (_) => random.nextInt(256)),
      ),
      'expires_at': issuedAt.add(ttl).toIso8601String(),
    };
    final signature = await signer.signBase64(utf8.encode(jsonEncode(body)));
    return jsonEncode({...body, 'signature': signature});
  }

  static Future<ContactPairingPayload> parseAndVerify(
    String raw, {
    DateTime? now,
  }) async {
    if (raw.isEmpty || raw.length > _maxPayloadCharacters) {
      throw const FormatException('QR имеет недопустимый размер');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> ||
        decoded['kind'] != kind ||
        decoded['v'] != version) {
      throw const FormatException('Это не QR защищённого контакта');
    }
    if (decoded.keys.any((key) => !_allowedKeys.contains(key))) {
      throw const FormatException('QR содержит недопустимые поля');
    }
    final userId = normalizeUserId(decoded['user_id']?.toString() ?? '');
    if (!isValidUserIdFormat(userId)) {
      throw const FormatException('Некорректный идентификатор контакта');
    }
    final authKey = decoded['auth_key']?.toString() ?? '';
    final identityKey = decoded['identity_key']?.toString() ?? '';
    final nonce = decoded['nonce']?.toString() ?? '';
    final expiresAt = DateTime.tryParse(
      decoded['expires_at']?.toString() ?? '',
    );
    final signature = decoded['signature']?.toString() ?? '';
    if (identityKey.isEmpty ||
        nonce.isEmpty ||
        expiresAt == null ||
        signature.isEmpty) {
      throw const FormatException('QR неполный');
    }
    if ((now ?? DateTime.now()).toUtc().isAfter(expiresAt.toUtc())) {
      throw const FormatException('Срок действия QR истёк');
    }
    final current = (now ?? DateTime.now()).toUtc();
    if (expiresAt.toUtc().isAfter(current.add(_maxTtl + _clockSkew))) {
      throw const FormatException('Срок действия QR слишком велик');
    }
    final publicBytes = decodeBase64Exact(
      authKey,
      expectedBytes: 32,
      field: 'auth_key',
    );
    decodeBase64Exact(identityKey, expectedBytes: 33, field: 'identity_key');
    decodeBase64Exact(nonce, expectedBytes: 24, field: 'nonce', urlSafe: true);
    final signatureBytes = decodeBase64Exact(
      signature,
      expectedBytes: 64,
      field: 'signature',
    );
    final body = <String, Object>{
      'kind': kind,
      'v': version,
      'user_id': userId,
      'auth_key': authKey,
      'identity_key': identityKey,
      'nonce': nonce,
      'expires_at': decoded['expires_at'].toString(),
    };
    final verified = await Ed25519().verify(
      utf8.encode(jsonEncode(body)),
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicBytes, type: KeyPairType.ed25519),
      ),
    );
    if (!verified) throw const FormatException('Подпись QR недействительна');
    return ContactPairingPayload(
      userId: userId,
      authPublicKey: authKey,
      identityPublicKey: identityKey,
      nonce: nonce,
      expiresAt: expiresAt,
    );
  }
}
