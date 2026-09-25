import 'dart:convert';
import 'dart:typed_data';

import '../crypto/auth_keypair.dart';
import '../crypto/media_crypto.dart';
import '../models/message.dart';
import 'api_client.dart';
import 'debug_log.dart';
import 'media_cache.dart';
import 'persistent_media_store.dart';
import 'ppc/personal_pc_media_store.dart';

typedef AttachmentUpload = ({
  Uint8List ciphertext,
  String mediaId,
  Map<String, dynamic> pointer,
});

/// Owns encrypted attachment transport, persistence, integrity and caching.
class AttachmentMediaService {
  const AttachmentMediaService(this._api);

  final ApiClient _api;

  void _configurePersonalStore(String userId, AuthKeyPair authKeyPair) {
    PersonalPcMediaStore.instance.configure(
      userId: userId,
      authKeyPair: authKeyPair,
    );
  }

  Future<String> _upload(
    Uint8List ciphertext,
    String filename, {
    required String userId,
    required AuthKeyPair authKeyPair,
  }) async {
    _configurePersonalStore(userId, authKeyPair);
    if (await PersonalPcMediaStore.instance.shouldHandleMedia()) {
      return PersonalPcMediaStore.instance.upload(ciphertext);
    }
    return _api.uploadMedia(ciphertext, filename);
  }

  Future<Uint8List> _download(
    String mediaId, {
    required String userId,
    required AuthKeyPair authKeyPair,
  }) async {
    if (mediaId.startsWith(PersonalPcMediaStore.mediaIdPrefix)) {
      _configurePersonalStore(userId, authKeyPair);
      return PersonalPcMediaStore.instance.download(mediaId);
    }
    return _api.downloadMedia(mediaId);
  }

  Future<AttachmentUpload> encryptAndUpload(
    Uint8List payload, {
    required String filename,
    required String mime,
    required String userId,
    required AuthKeyPair authKeyPair,
  }) async {
    final (ciphertext, pointer) = await MediaCrypto.encrypt(
      payload,
      filename: filename,
      mime: mime,
    );
    final mediaId = await _upload(
      ciphertext,
      filename,
      userId: userId,
      authKeyPair: authKeyPair,
    );
    try {
      await PersistentMediaStore.instance.putCiphertext(
        userId,
        mediaId,
        ciphertext,
      );
    } catch (error) {
      // A local cache failure must not orphan an already uploaded attachment.
      DebugLog.instance.warn(
        'media',
        'local ciphertext write failed media=$mediaId: $error',
      );
    }
    return (ciphertext: ciphertext, mediaId: mediaId, pointer: pointer);
  }

  void cachePlaintext(String mediaId, Uint8List plaintext) {
    MediaCache.instance.put(mediaId, plaintext);
  }

  Future<Uint8List> resolve(
    ChatMessage message, {
    required String userId,
    required AuthKeyPair authKeyPair,
    required bool forceDownload,
    required bool isolateFromMemoryCache,
  }) async {
    final encodedPointer = message.plaintext;
    if (encodedPointer == null || encodedPointer.isEmpty) {
      throw StateError('attachment metadata missing');
    }
    final decoded = jsonDecode(encodedPointer);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('attachment metadata must be an object');
    }
    if (decoded['pending'] == true) {
      throw StateError('attachment still uploading');
    }
    final mediaId = decoded['media_id'];
    if (mediaId is! String || mediaId.isEmpty) {
      throw const FormatException('media_id missing');
    }

    if (!isolateFromMemoryCache) {
      final cached = MediaCache.instance.get(mediaId);
      if (cached != null) return cached;
    }
    if (!forceDownload) throw StateError('autodownload_disabled');

    Uint8List? ciphertext;
    try {
      ciphertext = await PersistentMediaStore.instance.getCiphertext(
        userId,
        mediaId,
      );
    } catch (error) {
      DebugLog.instance.warn(
        'media',
        'local ciphertext read failed media=$mediaId: $error',
      );
    }
    if (ciphertext == null) {
      Object? lastError;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          ciphertext = await _download(
            mediaId,
            userId: userId,
            authKeyPair: authKeyPair,
          );
          break;
        } catch (error) {
          lastError = error;
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        }
      }
      if (ciphertext == null) {
        DebugLog.instance.error(
          'media',
          'download failed media=$mediaId',
          lastError,
        );
        throw StateError('Не удалось загрузить вложение: $lastError');
      }
      try {
        await PersistentMediaStore.instance.putCiphertext(
          userId,
          mediaId,
          ciphertext,
        );
      } catch (error) {
        DebugLog.instance.warn(
          'media',
          'local ciphertext write failed media=$mediaId: $error',
        );
      }
    }

    late final Uint8List plaintext;
    try {
      plaintext = await MediaCrypto.decrypt(ciphertext, decoded);
    } catch (error) {
      DebugLog.instance.error('media', 'decrypt failed media=$mediaId', error);
      rethrow;
    }
    if (!isolateFromMemoryCache) {
      MediaCache.instance.put(mediaId, plaintext);
    }
    return plaintext;
  }
}
