import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../security/device_crypto.dart';

/// E2EE wire content type for endpoint-created Single Use Reply Blocks.
const surbBundleContentType = 'ouo_surb_bundle';

/// One opaque, endpoint-created reply block. Infrastructure must never decode it.
class SurbReplyBlock {
  SurbReplyBlock({required this.bytes, required this.expiresAt})
    : id = identifier(bytes) {
    if (bytes.isEmpty || bytes.length > 256 * 1024) {
      throw const FormatException('invalid SURB size');
    }
    final now = DateTime.now().toUtc();
    final expiry = expiresAt.toUtc();
    if (!expiry.isAfter(now) ||
        expiry.isAfter(now.add(const Duration(days: 30)))) {
      throw const FormatException('invalid SURB expiry');
    }
  }

  final String id;
  final Uint8List bytes;
  final DateTime expiresAt;

  static String identifier(List<int> bytes) => sha256.convert([
    ...utf8.encode('OUO/SURB_ID/v1\u0000'),
    ...bytes,
  ]).toString();

  Map<String, dynamic> toJson() => {
    'surb_id': id,
    'surb_b64': base64Encode(bytes),
    'expires_at': expiresAt.toUtc().toIso8601String(),
  };

  factory SurbReplyBlock.fromJson(Map<String, dynamic> json) {
    final encoded = json['surb_b64'];
    final expiry = json['expires_at'];
    final claimedId = json['surb_id'];
    if (encoded is! String || expiry is! String || claimedId is! String) {
      throw const FormatException('invalid SURB fields');
    }
    final block = SurbReplyBlock(
      bytes: Uint8List.fromList(base64Decode(encoded)),
      expiresAt: DateTime.parse(expiry),
    );
    if (block.id != claimedId) {
      throw const FormatException('SURB identifier mismatch');
    }
    return block;
  }
}

/// Strict, bounded plaintext object which is encrypted by the existing
/// per-device Double Ratchet before it leaves the endpoint.
class SurbBundle {
  SurbBundle({required this.bundleId, required this.replyBlocks}) {
    if (bundleId.isEmpty || bundleId.length > 128) {
      throw const FormatException('invalid bundle id');
    }
    if (replyBlocks.isEmpty || replyBlocks.length > 16) {
      throw const FormatException('invalid SURB count');
    }
  }

  static const protocolVersion = 'ouo-surb-bundle/1';
  final String bundleId;
  final List<SurbReplyBlock> replyBlocks;

  String encode() => jsonEncode({
    'protocol_version': protocolVersion,
    'bundle_id': bundleId,
    'reply_blocks': replyBlocks.map((block) => block.toJson()).toList(),
  });

  factory SurbBundle.decode(String encoded) {
    if (encoded.length > 6 * 1024 * 1024) {
      throw const FormatException('SURB bundle too large');
    }
    final raw = jsonDecode(encoded);
    if (raw is! Map<String, dynamic> ||
        raw['protocol_version'] != protocolVersion ||
        raw['bundle_id'] is! String ||
        raw['reply_blocks'] is! List) {
      throw const FormatException('invalid SURB bundle');
    }
    final blocks = (raw['reply_blocks'] as List)
        .map((item) {
          if (item is! Map<String, dynamic>) {
            throw const FormatException('invalid SURB entry');
          }
          return SurbReplyBlock.fromJson(item);
        })
        .toList(growable: false);
    return SurbBundle(
      bundleId: raw['bundle_id'] as String,
      replyBlocks: blocks,
    );
  }
}

/// Device-encrypted persistent inbox of reply blocks received from peers.
/// [consume] removes a block before returning it, enforcing single-use in
/// this client process and across restarts.
class SurbDeliveryStore {
  SurbDeliveryStore._();
  static final instance = SurbDeliveryStore._();

  static const _prefix = 'ouo_surb_inbox_v1::';
  static const _maxPerPeer = 128;
  Future<void> _operation = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _operation.then((_) => action());
    _operation = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  String _key(String localUserId, String peerUserId) =>
      '$_prefix$localUserId::$peerUserId';

  Future<List<SurbReplyBlock>> _read(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final packed = prefs.getString(key);
    if (packed == null) return [];
    final clear = await DeviceCrypto.instance.decryptJson(packed);
    final items = clear?['reply_blocks'];
    if (items is! List) return [];
    final now = DateTime.now().toUtc();
    final blocks = <SurbReplyBlock>[];
    for (final item in items) {
      try {
        final block = SurbReplyBlock.fromJson(item as Map<String, dynamic>);
        if (block.expiresAt.toUtc().isAfter(now)) blocks.add(block);
      } catch (_) {
        // Fail closed per entry: corrupted/expired local material is discarded.
      }
    }
    return blocks;
  }

  Future<void> _write(String key, List<SurbReplyBlock> blocks) async {
    final prefs = await SharedPreferences.getInstance();
    if (blocks.isEmpty) {
      await prefs.remove(key);
      return;
    }
    final packed = await DeviceCrypto.instance.encryptJson({
      'reply_blocks': blocks.map((block) => block.toJson()).toList(),
    });
    await prefs.setString(key, packed);
  }

  Future<int> addBundle(
    String localUserId,
    String peerUserId,
    SurbBundle bundle,
  ) => _serial(() async {
    final key = _key(localUserId, peerUserId);
    final current = await _read(key);
    final byId = {for (final block in current) block.id: block};
    for (final block in bundle.replyBlocks) {
      byId.putIfAbsent(block.id, () => block);
    }
    final all = byId.values.toList()
      ..sort((a, b) => a.expiresAt.compareTo(b.expiresAt));
    if (all.length > _maxPerPeer) {
      all.removeRange(0, all.length - _maxPerPeer);
    }
    await _write(key, all);
    return all.length;
  });

  Future<SurbReplyBlock?> consume(String localUserId, String peerUserId) =>
      _serial(() async {
        final key = _key(localUserId, peerUserId);
        final current = await _read(key);
        if (current.isEmpty) {
          await _write(key, const []);
          return null;
        }
        final block = current.removeAt(0);
        await _write(key, current);
        return block;
      });
}
