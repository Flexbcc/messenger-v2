// storage-app :: pairing/pairing
// Сопряжение (PAIRING.md, WIRE.md §Сопряжение). Короткоживущий одноразовый код
// (TTL 5 мин) → запись pubkey пира в paired_peers, ответ своим публичным ключом.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../models/models.dart';
import '../storage/meta_db.dart';

class PairCode {
  final String code;
  final String qrSecret;
  final int expiresAt; // unix sec
  PairCode(this.code, this.qrSecret, this.expiresAt);
}

enum PairingAccessMode { qr, approval, pin, open }

class PendingPairRequest {
  const PendingPairRequest({
    required this.id,
    required this.peerPubkey,
    required this.nodeId,
    required this.name,
    required this.createdAt,
    required this.expiresAt,
  });

  final String id;
  final String peerPubkey;
  final String nodeId;
  final String name;
  final int createdAt;
  final int expiresAt;
}

/// Результат /ppc/pair.
sealed class PairResult {}

class PairOk extends PairResult {
  final String storagePubkey;
  PairOk(this.storagePubkey);
}

class PairBadCode extends PairResult {}

class PairDenied extends PairResult {}

class PairRateLimited extends PairResult {}

class PairPending extends PairResult {
  PairPending(this.request);
  final PendingPairRequest request;
}

class PairingManager {
  final MetaDb db;
  final String storagePubkey;
  final int ttlSeconds;
  final Random _rng;

  // code -> expiresAt (одноразовые).
  final Map<String, int> _codes = {};
  final Map<String, String> _qrSecrets = {};
  final Map<String, PendingPairRequest> _pending = {};
  final Set<String> _approved = {};
  final Map<String, int> _deniedUntil = {};
  String? _pinHash;
  String? _pinSalt;
  bool allowPin = false;
  bool allowOpen = false;
  int _failedPinAttempts = 0;
  int _pinBlockedUntil = 0;

  PairingManager({
    required this.db,
    required this.storagePubkey,
    this.ttlSeconds = 300,
    Random? rng,
  }) : _rng = rng ?? Random.secure();

  int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Сгенерировать 6-значный код для показа в UI (TTL 5 мин).
  PairCode issueCode() {
    final code = (_rng.nextInt(900000) + 100000).toString();
    final secret = base64UrlEncode(
      List<int>.generate(32, (_) => _rng.nextInt(256)),
    ).replaceAll('=', '');
    final exp = _now() + ttlSeconds;
    _codes[code] = exp;
    _qrSecrets[code] = secret;
    return PairCode(code, secret, exp);
  }

  /// Только для тестов/детерминизма: зарегистрировать конкретный код.
  void registerCode(String code) {
    _codes[code] = _now() + ttlSeconds;
  }

  List<PendingPairRequest> get pendingRequests {
    _prune();
    return _pending.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  void configurePin({String? hash, String? salt, bool enabled = false}) {
    _pinHash = hash;
    _pinSalt = salt;
    allowPin = enabled && hash != null && salt != null;
    _failedPinAttempts = 0;
    _pinBlockedUntil = 0;
  }

  void approve(String requestId) {
    final request = _pending.remove(requestId);
    if (request != null && request.expiresAt >= _now()) {
      _approved.add(requestId);
    }
  }

  void deny(String requestId) {
    _pending.remove(requestId);
    _approved.remove(requestId);
    _deniedUntil[requestId] = _now() + 120;
  }

  /// Обработать PAIR_REQUEST. Код валиден+не истёк → пишем пир, отдаём ключ.
  PairResult pair({
    required String code,
    String? qrSecret,
    String? pin,
    required String peerPubkey,
    required String nodeId,
    required String name,
  }) {
    _prune();
    final exp = _codes[code];
    final now = _now();
    if (exp == null || exp < now) {
      return PairBadCode();
    }
    final requestId = _requestId(code, nodeId, peerPubkey);
    if ((_deniedUntil[requestId] ?? 0) >= now) return PairDenied();
    final qrOk = qrSecret != null && _qrSecrets[code] == qrSecret;
    final approved = _approved.remove(requestId);
    var pinOk = false;
    if (pin != null && allowPin) {
      if (_pinBlockedUntil > now) return PairRateLimited();
      pinOk = _constantTimeEquals(_pinHash!, _hashPin(_pinSalt!, pin));
      if (!pinOk) {
        _failedPinAttempts++;
        if (_failedPinAttempts >= 5) {
          _pinBlockedUntil = now + 60;
          _failedPinAttempts = 0;
        }
        return PairDenied();
      }
      _failedPinAttempts = 0;
    }
    if (!qrOk && !approved && !pinOk && !allowOpen) {
      final pending = _pending.putIfAbsent(
        requestId,
        () => PendingPairRequest(
          id: requestId,
          peerPubkey: peerPubkey,
          nodeId: nodeId,
          name: name,
          createdAt: now,
          expiresAt: now + 120,
        ),
      );
      return PairPending(pending);
    }
    _codes.remove(code);
    _qrSecrets.remove(code);
    _pending.remove(requestId);
    db.upsertPeer(
      Peer(userUuid: nodeId, pubkey: peerPubkey, name: name, addedAt: now),
    );
    return PairOk(storagePubkey);
  }

  String _requestId(String code, String nodeId, String pubkey) =>
      base64UrlEncode(utf8.encode('$code\u0000$nodeId\u0000$pubkey'))
          .replaceAll('=', '');

  String _hashPin(String salt, String pin) {
    // The persisted salt avoids storing the PIN. The UI enforces 8+ digits;
    // rate limiting is the primary defence against online guessing.
    List<int> value = utf8.encode('$salt:$pin');
    for (var i = 0; i < 120000; i++) {
      value = sha256.convert(value).bytes;
    }
    return base64UrlEncode(value);
  }

  static String derivePinHash(String salt, String pin) {
    List<int> value = utf8.encode('$salt:$pin');
    for (var i = 0; i < 120000; i++) {
      value = sha256.convert(value).bytes;
    }
    return base64UrlEncode(value);
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  void _prune() {
    final now = _now();
    _codes.removeWhere((_, expiry) => expiry < now);
    _pending.removeWhere((_, request) => request.expiresAt < now);
    _deniedUntil.removeWhere((_, expiry) => expiry < now);
  }
}
