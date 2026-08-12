import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../crypto/auth_keypair.dart';
import 'personal_pc_media_policy.dart';
import 'ppc_client.dart';
import 'ppc_vault.dart';

/// Thrown when direct-mode PPC media storage is unavailable or misconfigured.
class PersonalPcMediaStoreException implements Exception {
  PersonalPcMediaStoreException(this.message);
  final String message;
  @override
  String toString() => 'PersonalPcMediaStoreException: $message';
}

/// Direct-mode chat media on a paired home PC (storage-app PPC blob store).
class PersonalPcMediaStore {
  PersonalPcMediaStore._();
  static final instance = PersonalPcMediaStore._();

  static const mediaIdPrefix = 'ppc:';

  static final _sha256 = Sha256();

  PpcClient? _client;
  String? _userId;
  AuthKeyPair? _authKeyPair;

  /// Bind session credentials before upload/download (lazy restore on first use).
  void configure({required String userId, required AuthKeyPair authKeyPair}) {
    if (_userId == userId &&
        _authKeyPair == authKeyPair &&
        _client?.isPaired == true) {
      return;
    }
    _userId = userId;
    _authKeyPair = authKeyPair;
    _client = null;
  }

  /// True when vault has pairing state and transport restores successfully.
  Future<bool> get isActive async {
    if (!await PpcVault().isPaired()) return false;
    return _ensureClient();
  }

  /// True when catalog policy selects sender-device PPC and client restores.
  Future<bool> shouldHandleMedia() async {
    if (!await PersonalPcMediaPolicy.shouldUsePersonalPcMedia()) return false;
    return _ensureClient();
  }

  /// PUT ciphertext at content-addressed key; returns `ppc:<hex-sha256>`.
  Future<String> upload(Uint8List ciphertext) async {
    if (!await _ensureClient()) {
      throw PersonalPcMediaStoreException(
        'not paired with personal PC storage — pair in Settings first',
      );
    }
    final userId = _userId!;
    final key = await _sha256Hex(ciphertext);
    await _client!.put(userId: userId, key: key, ciphertext: ciphertext);
    return '$mediaIdPrefix$key';
  }

  /// GET ciphertext blob by `ppc:` media id.
  Future<Uint8List> download(String mediaId) async {
    if (!mediaId.startsWith(mediaIdPrefix)) {
      throw ArgumentError('not a PPC media id: $mediaId');
    }
    if (!await _ensureClient()) {
      throw PersonalPcMediaStoreException(
        'not paired with personal PC storage — pair in Settings first',
      );
    }
    final key = mediaId.substring(mediaIdPrefix.length);
    final bytes = await _client!.get(userId: _userId!, key: key);
    if (bytes == null) {
      throw PersonalPcMediaStoreException(
        'media not found on personal PC: $key',
      );
    }
    return Uint8List.fromList(bytes);
  }

  Future<bool> _ensureClient() async {
    if (_client?.isPaired == true) return true;
    final userId = _userId;
    final authKeyPair = _authKeyPair;
    if (userId == null || authKeyPair == null) return false;
    final client = PpcClient.fromAuth(
      authKeyPair: authKeyPair,
      nodeId: userId,
      deviceName: 'phone',
    );
    if (!await client.restoreFromVault()) return false;
    _client = client;
    return true;
  }

  static Future<String> _sha256Hex(List<int> body) async {
    final digest = await _sha256.hash(body);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
