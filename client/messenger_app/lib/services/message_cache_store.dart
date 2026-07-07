import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/message.dart';
import '../security/device_crypto.dart';

/// Encrypted local message cache. SQLite on desktop/mobile; SharedPreferences on web
/// so decrypted plaintext survives page reload (Signal message keys are single-use).
class MessageCacheStore {
  MessageCacheStore._();
  static final instance = MessageCacheStore._();

  static const _dbName = 'messages_cache.db';
  static const _schemaVersion = 1;
  static const _webPrefix = 'msgcache_web_v1';
  static const _webMaxPerConversation = 200;

  Database? _db;
  final _crypto = DeviceCrypto.instance;

  Future<Database> _database() async {
    if (_db != null) return _db!;
    final dir = await getApplicationSupportDirectory();
    final path = '${dir.path}/$_dbName';
    _db = await openDatabase(
      path,
      version: _schemaVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE cached_messages (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            conversation_id TEXT NOT NULL,
            sender_user_id TEXT NOT NULL,
            sender_device_id TEXT,
            content_type TEXT NOT NULL,
            crypto_version TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            payload TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_cached_messages_conv ON cached_messages(user_id, conversation_id, created_at)',
        );
      },
    );
    return _db!;
  }

  String _webConvKey(String userId, String conversationId) => '$_webPrefix::$userId::$conversationId';

  Map<String, dynamic> _messageToJson(ChatMessage message) => {
        'id': message.id,
        'conversation_id': message.conversationId,
        'sender_user_id': message.senderUserId,
        'sender_device_id': message.senderDeviceId,
        'content_type': message.contentType,
        'crypto_version': message.cryptoVersion,
        'created_at': message.createdAt.millisecondsSinceEpoch,
        'plaintext': message.plaintext,
        'ciphertext': message.ciphertext,
        'decrypt_failed': message.decryptFailed,
        'reply_to_message_id': message.replyToMessageId,
        'reply_preview': message.replyPreview,
      };

  ChatMessage _messageFromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        conversationId: json['conversation_id'] as String,
        senderUserId: json['sender_user_id'] as String,
        senderDeviceId: json['sender_device_id'] as String?,
        ciphertext: json['ciphertext'] as String? ?? '',
        contentType: json['content_type'] as String,
        cryptoVersion: json['crypto_version'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(json['created_at'] as int),
        plaintext: json['plaintext'] as String?,
        decryptFailed: json['decrypt_failed'] as bool? ?? false,
        replyToMessageId: json['reply_to_message_id'] as String?,
        replyPreview: json['reply_preview'] as String?,
      );

  Future<void> _webSaveConversation(String userId, String conversationId, List<ChatMessage> messages) async {
    final sorted = List<ChatMessage>.from(messages)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final slice = sorted.length > _webMaxPerConversation
        ? sorted.sublist(sorted.length - _webMaxPerConversation)
        : sorted;
    final packed = await _crypto.encryptJson({
      'items': slice.map(_messageToJson).toList(),
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_webConvKey(userId, conversationId), packed);
  }

  Future<List<ChatMessage>> _webLoadConversation(String userId, String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    final packed = prefs.getString(_webConvKey(userId, conversationId));
    if (packed == null) return [];
    final decoded = await _crypto.decryptJson(packed);
    if (decoded == null) return [];
    final items = decoded['items'] as List<dynamic>? ?? [];
    return items.map((e) => _messageFromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> upsertMessage(String userId, ChatMessage message) async {
    message = await _mergeWithExisting(userId, message);
    if (kIsWeb) {
      final existing = await _webLoadConversation(userId, message.conversationId);
      final byId = {for (final m in existing) m.id: m};
      byId[message.id] = message;
      await _webSaveConversation(userId, message.conversationId, byId.values.toList());
      return;
    }
    final payload = await _crypto.encryptJson({
      'plaintext': message.plaintext,
      'ciphertext': message.ciphertext,
      'decrypt_failed': message.decryptFailed,
      'reply_to_message_id': message.replyToMessageId,
      'reply_preview': message.replyPreview,
    });
    final db = await _database();
    await db.insert(
      'cached_messages',
      {
        'id': message.id,
        'user_id': userId,
        'conversation_id': message.conversationId,
        'sender_user_id': message.senderUserId,
        'sender_device_id': message.senderDeviceId,
        'content_type': message.contentType,
        'crypto_version': message.cryptoVersion,
        'created_at': message.createdAt.millisecondsSinceEpoch,
        'payload': payload,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertMessages(String userId, List<ChatMessage> messages) async {
    if (messages.isEmpty) return;
    final merged = <ChatMessage>[];
    for (final m in messages) {
      merged.add(await _mergeWithExisting(userId, m));
    }
    if (kIsWeb) {
      final convId = merged.first.conversationId;
      final existing = await _webLoadConversation(userId, convId);
      final byId = {for (final m in existing) m.id: m};
      for (final m in merged) {
        byId[m.id] = m;
      }
      await _webSaveConversation(userId, convId, byId.values.toList());
      return;
    }
    final db = await _database();
    final batch = db.batch();
    for (final message in merged) {
      final payload = await _crypto.encryptJson({
        'plaintext': message.plaintext,
        'ciphertext': message.ciphertext,
        'decrypt_failed': message.decryptFailed,
        'reply_to_message_id': message.replyToMessageId,
        'reply_preview': message.replyPreview,
      });
      batch.insert(
        'cached_messages',
        {
          'id': message.id,
          'user_id': userId,
          'conversation_id': message.conversationId,
          'sender_user_id': message.senderUserId,
          'sender_device_id': message.senderDeviceId,
          'content_type': message.contentType,
          'crypto_version': message.cryptoVersion,
          'created_at': message.createdAt.millisecondsSinceEpoch,
          'payload': payload,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Keep previously decrypted plaintext when a later upsert would wipe it.
  Future<ChatMessage> _mergeWithExisting(String userId, ChatMessage message) async {
    if (kIsWeb) {
      final existing = await _webLoadConversation(userId, message.conversationId);
      final prev = existing.where((m) => m.id == message.id).firstOrNull;
      return _mergeMessages(prev, message);
    }
    final db = await _database();
    final rows = await db.query(
      'cached_messages',
      where: 'user_id = ? AND id = ?',
      whereArgs: [userId, message.id],
      limit: 1,
    );
    if (rows.isEmpty) return message;
    final prev = await _rowToMessage(rows.first);
    if (prev == null) return message;
    return _mergeMessages(prev, message);
  }

  ChatMessage _mergeMessages(ChatMessage? prev, ChatMessage next) {
    if (prev == null) return next;
    final keepPrevPlaintext = prev.plaintext != null &&
        prev.plaintext!.isNotEmpty &&
        !prev.decryptFailed &&
        (next.plaintext == null || next.plaintext!.isEmpty || next.decryptFailed);
    if (!keepPrevPlaintext) return next;
    return ChatMessage(
      id: next.id,
      conversationId: next.conversationId,
      senderUserId: next.senderUserId,
      senderDeviceId: next.senderDeviceId,
      ciphertext: next.ciphertext.isNotEmpty ? next.ciphertext : prev.ciphertext,
      contentType: next.contentType,
      cryptoVersion: next.cryptoVersion,
      createdAt: next.createdAt,
      plaintext: prev.plaintext,
      decryptFailed: false,
      replyToMessageId: next.replyToMessageId ?? prev.replyToMessageId,
      replyPreview: next.replyPreview ?? prev.replyPreview,
      favoriteSourceConversationId: next.favoriteSourceConversationId,
      favoriteSourceMessageId: next.favoriteSourceMessageId,
      favoriteSourceTitle: next.favoriteSourceTitle,
      favoriteSenderLabel: next.favoriteSenderLabel,
    );
  }

  Future<List<ChatMessage>> loadConversation(String userId, String conversationId, {int limit = 200}) async {
    if (kIsWeb) {
      final all = await _webLoadConversation(userId, conversationId);
      if (all.length <= limit) return all;
      return all.sublist(all.length - limit);
    }
    final db = await _database();
    final rows = await db.query(
      'cached_messages',
      where: 'user_id = ? AND conversation_id = ?',
      whereArgs: [userId, conversationId],
      orderBy: 'created_at ASC',
      limit: limit,
    );
    final out = <ChatMessage>[];
    for (final row in rows) {
      final msg = await _rowToMessage(row);
      if (msg != null) out.add(msg);
    }
    return out;
  }

  Future<ChatMessage?> _rowToMessage(Map<String, Object?> row) async {
    final payload = await _crypto.decryptJson(row['payload'] as String);
    if (payload == null) return null;
    return ChatMessage(
      id: row['id'] as String,
      conversationId: row['conversation_id'] as String,
      senderUserId: row['sender_user_id'] as String,
      senderDeviceId: row['sender_device_id'] as String?,
      ciphertext: payload['ciphertext'] as String? ?? '',
      contentType: row['content_type'] as String,
      cryptoVersion: row['crypto_version'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      plaintext: payload['plaintext'] as String?,
      decryptFailed: payload['decrypt_failed'] as bool? ?? false,
      replyToMessageId: payload['reply_to_message_id'] as String?,
      replyPreview: payload['reply_preview'] as String?,
    );
  }

  Future<void> clearUser(String userId) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final prefix = '$_webPrefix::$userId::';
      for (final key in prefs.getKeys()) {
        if (key.startsWith(prefix)) await prefs.remove(key);
      }
      return;
    }
    final db = await _database();
    await db.delete('cached_messages', where: 'user_id = ?', whereArgs: [userId]);
  }

  Future<void> clearConversation(String userId, String conversationId) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_webConvKey(userId, conversationId));
      return;
    }
    final db = await _database();
    await db.delete(
      'cached_messages',
      where: 'user_id = ? AND conversation_id = ?',
      whereArgs: [userId, conversationId],
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
