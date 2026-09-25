import 'dart:typed_data';

import '../config.dart';
import '../crypto/crypto_service.dart';
import '../models/conversation.dart';
import 'api_client.dart';
import 'contact_pairing_store.dart';
import 'debug_log.dart';

class EncryptedMessagePayload {
  const EncryptedMessagePayload(this.fallback, this.deviceEnvelopes);

  final String fallback;
  final List<Map<String, String>> deviceEnvelopes;
}

/// Builds recipient-device envelopes without owning application state.
///
/// Account-wide Signal sessions are migration-only. The default contract is
/// fail-closed when device discovery or per-device session setup fails.
class MessageEncryptionService {
  const MessageEncryptionService({
    required ApiClient api,
    required CryptoService crypto,
    ContactPairingStore? pairingStore,
  }) : _api = api,
       _crypto = crypto,
       _pairingStore = pairingStore;

  final ApiClient _api;
  final CryptoService _crypto;
  final ContactPairingStore? _pairingStore;

  ContactPairingStore get _pairings => _pairingStore ?? ContactPairingStore();

  Future<Uint8List> decryptDirect({
    required String senderUserId,
    required String? senderDeviceId,
    required String ciphertext,
  }) async {
    final pinnedIdentity = await _pairings.pinnedIdentity(senderUserId);
    if (pinnedIdentity != null && senderDeviceId != pinnedIdentity.deviceId) {
      throw StateError(
        'Сообщение пришло не с устройства, закреплённого проверенным QR',
      );
    }
    if (senderDeviceId != null && senderDeviceId.isNotEmpty) {
      try {
        return await _crypto.decrypt(
          senderUserId,
          ciphertext,
          senderDeviceId: senderDeviceId,
        );
      } catch (error) {
        if (!AppConfig.allowLegacyAccountWideE2ee) {
          DebugLog.instance.error(
            'crypto',
            'per-device decryption failed closed: $error',
          );
          throw StateError(
            'Не удалось безопасно расшифровать сообщение устройства отправителя',
          );
        }
        DebugLog.instance.warn(
          'crypto',
          'explicit legacy account-wide E2EE decrypt enabled: $error',
        );
      }
    } else if (!AppConfig.allowLegacyAccountWideE2ee) {
      throw StateError('В сообщении отсутствует идентификатор устройства');
    }
    return _crypto.decrypt(senderUserId, ciphertext);
  }

  Future<EncryptedMessagePayload> encrypt({
    required Conversation conversation,
    required Uint8List plaintext,
    required String currentUserId,
    required String currentDeviceId,
    required String? directPeerUserId,
    Future<void> Function(String userId)? ensureLegacySession,
  }) async {
    if (conversation.isGroup) {
      final envelopes = <Map<String, String>>[];
      for (final userId in conversation.participantUserIds) {
        await _appendDeviceEnvelopes(
          envelopes,
          userId,
          plaintext,
          excludeDeviceId: userId == currentUserId ? currentDeviceId : null,
        );
      }
      if (envelopes.isEmpty) {
        throw StateError('В группе нет устройств с доступными ключами');
      }
      return EncryptedMessagePayload(envelopes.first['ciphertext']!, envelopes);
    }

    final peerUserId = directPeerUserId;
    if (peerUserId == null) {
      throw StateError('В чате нет собеседника');
    }

    try {
      final envelopes = <Map<String, String>>[];
      await _appendDeviceEnvelopes(envelopes, peerUserId, plaintext);
      await _appendDeviceEnvelopes(
        envelopes,
        currentUserId,
        plaintext,
        excludeDeviceId: currentDeviceId,
      );
      if (envelopes.isEmpty) {
        throw StateError('Нет устройств с доступными per-device ключами');
      }
      return EncryptedMessagePayload(envelopes.first['ciphertext']!, envelopes);
    } catch (error) {
      if (!AppConfig.allowLegacyAccountWideE2ee) {
        DebugLog.instance.error(
          'crypto',
          'per-device encryption failed closed: $error',
        );
        throw StateError(
          'Не удалось безопасно зашифровать сообщение для устройств получателя',
        );
      }
      DebugLog.instance.warn(
        'crypto',
        'explicit legacy account-wide E2EE fallback enabled: $error',
      );
    }

    if (ensureLegacySession == null) {
      throw StateError('Legacy E2EE session initializer is unavailable');
    }
    await ensureLegacySession(peerUserId);
    final ciphertext = await _crypto.encrypt(peerUserId, plaintext);
    return EncryptedMessagePayload(ciphertext, const []);
  }

  Future<void> _appendDeviceEnvelopes(
    List<Map<String, String>> target,
    String userId,
    Uint8List plaintext, {
    String? excludeDeviceId,
  }) async {
    final devices = await _api.getUserDeviceBundles(
      userId,
      excludeDeviceId: excludeDeviceId,
    );
    final pinnedIdentity = await _pairings.pinnedIdentity(userId);
    var matchedPinnedIdentity = pinnedIdentity == null;
    for (final raw in devices) {
      final device = raw;
      final deviceId = device['device_id']?.toString() ?? '';
      if (deviceId.isEmpty) continue;
      if (pinnedIdentity != null) {
        if (deviceId != pinnedIdentity.deviceId ||
            device['identity_key'] != pinnedIdentity.identityKey) {
          continue;
        }
        matchedPinnedIdentity = true;
      }
      final hadSession = await _crypto.hasSessionWith(
        userId,
        deviceId: deviceId,
      );
      if (!hadSession) {
        final bundle = await _api.getDevicePreKeyBundle(userId, deviceId);
        await _crypto.establishSessionFromBundle(
          userId,
          bundle,
          deviceId: deviceId,
        );
      }
      final ciphertext = await _crypto.encrypt(
        userId,
        plaintext,
        recipientDeviceId: deviceId,
      );
      DebugLog.instance.info(
        'crypto',
        'encrypt device=${deviceId.length > 8 ? '${deviceId.substring(0, 8)}…' : deviceId} '
            'session=${hadSession ? 'existing' : 'new'} '
            'type=${ciphertext.contains('"t":3') ? 'prekey' : 'ratchet'}',
      );
      target.add({
        'device_id': deviceId,
        'ciphertext': ciphertext,
      });
    }
    if (!matchedPinnedIdentity) {
      throw StateError(
        'Ни одно устройство контакта не совпало с ключом проверенного QR',
      );
    }
  }
}
