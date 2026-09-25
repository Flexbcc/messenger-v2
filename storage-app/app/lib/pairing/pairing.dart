// storage-app :: pairing/pairing
// Сопряжение (PAIRING.md, WIRE.md §Сопряжение). Короткоживущий одноразовый код
// (TTL 5 мин) → запись pubkey пира в paired_peers, ответ своим публичным ключом.
library;

import 'dart:math';

import '../models/models.dart';
import '../storage/meta_db.dart';

class PairCode {
  final String code;
  final int expiresAt; // unix sec
  PairCode(this.code, this.expiresAt);
}

/// Результат /ppc/pair.
sealed class PairResult {}

class PairOk extends PairResult {
  final String storagePubkey;
  PairOk(this.storagePubkey);
}

class PairBadCode extends PairResult {}

class PairingManager {
  final MetaDb db;
  final String storagePubkey;
  final int ttlSeconds;
  final Random _rng;

  // code -> expiresAt (одноразовые).
  final Map<String, int> _codes = {};

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
    final exp = _now() + ttlSeconds;
    _codes[code] = exp;
    return PairCode(code, exp);
  }

  /// Только для тестов/детерминизма: зарегистрировать конкретный код.
  void registerCode(String code) {
    _codes[code] = _now() + ttlSeconds;
  }

  /// Обработать PAIR_REQUEST. Код валиден+не истёк → пишем пир, отдаём ключ.
  PairResult pair({
    required String code,
    required String peerPubkey,
    required String nodeId,
    required String name,
  }) {
    final exp = _codes[code];
    final now = _now();
    if (exp == null || exp < now) {
      return PairBadCode();
    }
    _codes.remove(code); // одноразовость
    db.upsertPeer(Peer(
      userUuid: nodeId,
      pubkey: peerPubkey,
      name: name,
      addedAt: now,
    ));
    return PairOk(storagePubkey);
  }
}
