// storage-app :: storage/meta_db
// SQLite-метаданные (SETTINGS.md §4). Только метаданные; содержимое — на ФС.
// At-rest: meta.db.enc (AES-GCM, ключ из OS-keystore) — см. meta_db_crypto.dart.
library;

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../models/models.dart';
import 'meta_db_crypto.dart';
import 'secure_key_store.dart';

class MetaDb {
  final Database _db;
  final String _allowedRoot;
  final List<int>? _encryptionKey;

  MetaDb._(this._db, this._allowedRoot, this._encryptionKey);

  /// Открыть/создать meta.db в allowed_root. WAL-режим (SETTINGS.md §4).
  /// При наличии ключа: расшифровать meta.db.enc → meta.db; при close — обратно.
  /// Если после краша есть и meta.db, и meta.db.enc — см. [MetaDbCrypto.recoverCrashState].
  static Future<MetaDb> open(String allowedRoot) async {
    final key = await SecureKeyStore.loadOrCreateMetaDbKey();
    final dbPath = MetaDbCrypto.dbPath(allowedRoot);
    final encPath = MetaDbCrypto.encryptedPath(dbPath);

    if (key != null) {
      final plainExists = await File(dbPath).exists();
      final encExists = await File(encPath).exists();
      if (encExists && plainExists) {
        await MetaDbCrypto.recoverCrashState(dbPath, encPath, key);
      } else if (encExists) {
        await MetaDbCrypto.decryptDatabaseFile(encPath, dbPath, key);
      }
    }

    final db = sqlite3.open(dbPath);
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('''
      CREATE TABLE IF NOT EXISTS blobs (
        user_uuid   TEXT NOT NULL,
        hash        TEXT NOT NULL,
        size        INTEGER NOT NULL,
        created_at  INTEGER NOT NULL,
        last_access INTEGER NOT NULL,
        refcount    INTEGER NOT NULL DEFAULT 1,
        state       TEXT NOT NULL DEFAULT 'present',
        PRIMARY KEY (user_uuid, hash)
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS peers (
        user_uuid   TEXT PRIMARY KEY,
        pubkey      TEXT NOT NULL,
        name        TEXT NOT NULL DEFAULT '',
        added_at    INTEGER NOT NULL,
        quota_bytes INTEGER NOT NULL DEFAULT 0,
        revoked     INTEGER NOT NULL DEFAULT 0
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS audit_log (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        ts          INTEGER NOT NULL,
        op          TEXT NOT NULL,
        user_uuid   TEXT,
        hash        TEXT,
        size        INTEGER NOT NULL DEFAULT 0,
        result      TEXT NOT NULL,
        detail      TEXT NOT NULL DEFAULT ''
      );
    ''');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(ts DESC);');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_blobs_last_access ON blobs(last_access);');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_blobs_user ON blobs(user_uuid);');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_peers_pubkey ON peers(pubkey);');
    return MetaDb._(db, allowedRoot, key);
  }

  // ---- peers / pairing ----

  /// Множество активных (не отозванных) публичных ключей — «paired_peers».
  Set<String> pairedPubkeys() {
    final rs = _db.select('SELECT pubkey FROM peers WHERE revoked = 0;');
    return {for (final r in rs) r['pubkey'] as String};
  }

  bool isPaired(String pubkey) {
    final rs = _db.select(
        'SELECT 1 FROM peers WHERE pubkey = ? AND revoked = 0 LIMIT 1;',
        [pubkey]);
    return rs.isNotEmpty;
  }

  void upsertPeer(Peer peer) {
    _db.execute('''
      INSERT INTO peers (user_uuid, pubkey, name, added_at, quota_bytes, revoked)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(user_uuid) DO UPDATE SET
        pubkey = excluded.pubkey,
        name = excluded.name,
        quota_bytes = excluded.quota_bytes,
        revoked = 0;
    ''', [
      peer.userUuid,
      peer.pubkey,
      peer.name,
      peer.addedAt,
      peer.quotaBytes,
      peer.revoked ? 1 : 0,
    ]);
  }

  int? peerQuota(String userUuid) {
    final rs = _db.select(
        'SELECT quota_bytes FROM peers WHERE user_uuid = ? AND revoked = 0;',
        [userUuid]);
    if (rs.isEmpty) return null;
    return rs.first['quota_bytes'] as int;
  }

  /// Активные (не отозванные) пиры для UI.
  List<Peer> listPeers() {
    final rs = _db.select('''
      SELECT user_uuid, pubkey, name, added_at, quota_bytes, revoked
      FROM peers WHERE revoked = 0
      ORDER BY added_at DESC;
    ''');
    return rs
        .map((r) => Peer(
              userUuid: r['user_uuid'] as String,
              pubkey: r['pubkey'] as String,
              name: r['name'] as String,
              addedAt: r['added_at'] as int,
              quotaBytes: r['quota_bytes'] as int,
              revoked: (r['revoked'] as int) != 0,
            ))
        .toList();
  }

  /// Отозвать pairing (PAIRING.md «Revoke»). Блобы не трогаем.
  void revokePeer(String userUuid) {
    _db.execute(
        'UPDATE peers SET revoked = 1 WHERE user_uuid = ?;', [userUuid]);
  }

  /// Удалить метаданные блобов пользователя (перед wipe на ФС).
  void deleteUserBlobs(String userUuid) {
    _db.execute('DELETE FROM blobs WHERE user_uuid = ?;', [userUuid]);
  }

  /// Последняя активность пира (max last_access по его блобам), unix sec или null.
  int? peerLastAccess(String userUuid) {
    final rs = _db.select(
        'SELECT MAX(last_access) AS la FROM blobs WHERE user_uuid = ?;',
        [userUuid]);
    if (rs.isEmpty || rs.first['la'] == null) return null;
    return rs.first['la'] as int;
  }

  // ---- blobs ----

  /// Метаданные блоба, либо null.
  ({int size})? statBlob(String userUuid, String hash) {
    final rs = _db.select(
        'SELECT size FROM blobs WHERE user_uuid = ? AND hash = ?;',
        [userUuid, hash]);
    if (rs.isEmpty) return null;
    return (size: rs.first['size'] as int);
  }

  void insertBlob({
    required String userUuid,
    required String hash,
    required int size,
    required int now,
  }) {
    _db.execute('''
      INSERT INTO blobs (user_uuid, hash, size, created_at, last_access, refcount, state)
      VALUES (?, ?, ?, ?, ?, 1, 'present')
      ON CONFLICT(user_uuid, hash) DO UPDATE SET
        last_access = excluded.last_access,
        refcount = refcount + 1,
        state = 'present';
    ''', [userUuid, hash, size, now, now]);
  }

  void touchBlob(String userUuid, String hash, int now) {
    _db.execute(
        'UPDATE blobs SET last_access = ? WHERE user_uuid = ? AND hash = ?;',
        [now, userUuid, hash]);
  }

  /// Уменьшить refcount; при 0 — state='pending_delete'. Нет строки → 0.
  int decrementRef(String userUuid, String hash) {
    final rs = _db.select(
        'SELECT refcount FROM blobs WHERE user_uuid = ? AND hash = ?;',
        [userUuid, hash]);
    if (rs.isEmpty) return 0;
    final current = rs.first['refcount'] as int;
    if (current <= 0) return 0;
    final newRef = current - 1;
    if (newRef <= 0) {
      markBlobPendingDelete(userUuid, hash);
      return 0;
    }
    _db.execute(
        'UPDATE blobs SET refcount = ? WHERE user_uuid = ? AND hash = ?;',
        [newRef, userUuid, hash]);
    return newRef;
  }

  void markBlobPendingDelete(String userUuid, String hash) {
    _db.execute('''
      UPDATE blobs SET refcount = 0, state = 'pending_delete'
      WHERE user_uuid = ? AND hash = ?;
    ''', [userUuid, hash]);
  }

  void deleteBlob(String userUuid, String hash) {
    _db.execute('DELETE FROM blobs WHERE user_uuid = ? AND hash = ?;',
        [userUuid, hash]);
  }

  static const _activeBlob =
      "refcount > 0 AND state = 'present'";

  /// Удалить GC-кандидатов; вернуть пары (user_uuid, hash) до удаления.
  List<({String userUuid, String hash})> collectGarbage({int ttlDays = 0}) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final ttlCutoff = ttlDays > 0 ? now - ttlDays * 86400 : now;
    final rs = _db.select('''
      SELECT user_uuid, hash FROM blobs WHERE
        (refcount <= 0 AND state = 'pending_delete')
        OR (? > 0 AND last_access < ?);
    ''', [ttlDays, ttlCutoff]);
    final removed = rs
        .map((r) => (
              userUuid: r['user_uuid'] as String,
              hash: r['hash'] as String,
            ))
        .toList();
    _db.execute('''
      DELETE FROM blobs WHERE
        (refcount <= 0 AND state = 'pending_delete')
        OR (? > 0 AND last_access < ?);
    ''', [ttlDays, ttlCutoff]);
    return removed;
  }

  /// (used_bytes, used_files) для пользователя (только активные блобы).
  ({int bytes, int files}) userUsage(String userUuid) {
    final rs = _db.select(
        'SELECT COALESCE(SUM(size),0) AS b, COUNT(*) AS c FROM blobs WHERE user_uuid = ? AND $_activeBlob;',
        [userUuid]);
    return (bytes: rs.first['b'] as int, files: rs.first['c'] as int);
  }

  /// Глобальные (used_bytes, used_files) по всем пользователям.
  ({int bytes, int files}) globalUsage() {
    final rs = _db.select(
        'SELECT COALESCE(SUM(size),0) AS b, COUNT(*) AS c FROM blobs WHERE $_activeBlob;');
    return (bytes: rs.first['b'] as int, files: rs.first['c'] as int);
  }

  // ---- audit_log ----

  void appendAudit({
    required int ts,
    required String op,
    String? userUuid,
    String? hash,
    int size = 0,
    required String result,
    String detail = '',
  }) {
    _db.execute('''
      INSERT INTO audit_log (ts, op, user_uuid, hash, size, result, detail)
      VALUES (?, ?, ?, ?, ?, ?, ?);
    ''', [ts, op, userUuid, hash, size, result, detail]);
    // Ротация: держим последние 5000 записей (SETTINGS.md §6).
    _db.execute('''
      DELETE FROM audit_log WHERE id NOT IN (
        SELECT id FROM audit_log ORDER BY id DESC LIMIT 5000
      );
    ''');
  }

  List<AuditEntry> listAudit({int limit = 200, int offset = 0}) {
    final rs = _db.select('''
      SELECT id, ts, op, user_uuid, hash, size, result, detail
      FROM audit_log ORDER BY id DESC LIMIT ? OFFSET ?;
    ''', [limit, offset]);
    return rs
        .map((r) => AuditEntry(
              id: r['id'] as int,
              ts: r['ts'] as int,
              op: r['op'] as String,
              userUuid: r['user_uuid'] as String?,
              hash: r['hash'] as String?,
              size: r['size'] as int,
              result: r['result'] as String,
              detail: r['detail'] as String,
            ))
        .toList();
  }

  /// Checkpoint WAL и записать encrypted snapshot на диск, не закрывая SQLite.
  /// Для long-running серверов: meta.db.enc обновляется, plaintext остаётся открыт.
  Future<void> flushEncrypt() async {
    final key = _encryptionKey;
    if (key == null) return;
    _db.execute('PRAGMA wal_checkpoint(FULL);');
    final dbPath = MetaDbCrypto.dbPath(_allowedRoot);
    if (await File(dbPath).exists()) {
      await MetaDbCrypto.encryptDatabaseCopy(dbPath, key);
    }
  }

  /// Закрыть SQLite и зашифровать meta.db → meta.db.enc (если ключ доступен).
  Future<void> close() async {
    _db.execute('PRAGMA wal_checkpoint(FULL);');
    _db.dispose();
    final key = _encryptionKey;
    if (key == null) return;
    final dbPath = MetaDbCrypto.dbPath(_allowedRoot);
    if (await File(dbPath).exists()) {
      await MetaDbCrypto.encryptDatabaseFile(dbPath, key);
    }
  }
}
