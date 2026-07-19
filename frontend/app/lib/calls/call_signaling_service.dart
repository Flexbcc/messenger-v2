import 'dart:convert';
import 'dart:typed_data';

import '../crypto/crypto_service.dart';
import 'call_signal.dart';

/// Encodes/decodes call signaling messages (spec/0303_CALLS.md, ADR-0008).
///
/// Deliberately network-agnostic — like CryptoService itself, this module
/// never touches ApiClient. The caller (AppController, once wired in a
/// later step) is responsible for resolving the 1:1 conversation with the
/// peer and posting the resulting ciphertext via `content_type` matching
/// [CallSignalType.contentType], exactly as `_distributeGroupKeyIfNeeded`
/// already does for `sender_key_distribution`. No WebRTC/media handling
/// happens here — this step is signaling plumbing only.
class CallSignalingService {
  CallSignalingService(this._crypto);

  final CryptoService _crypto;

  /// True for any `content_type` this service understands — callers use
  /// this to route incoming messages away from the chat-bubble path,
  /// mirroring the `contentType == 'sender_key_distribution'` check.
  static bool isCallSignal(String contentType) => CallSignalTypeContentType.fromContentType(contentType) != null;

  Future<String> encodeOffer({required String peerUserId, required String callId, required CallKind kind, required String sdp}) {
    return _encrypt(peerUserId, CallSignal(type: CallSignalType.offer, callId: callId, kind: kind, sdp: sdp));
  }

  Future<String> encodeAnswer({required String peerUserId, required String callId, required String sdp}) {
    return _encrypt(peerUserId, CallSignal(type: CallSignalType.answer, callId: callId, sdp: sdp));
  }

  Future<String> encodeIceCandidate({required String peerUserId, required String callId, required Map<String, dynamic> candidate}) {
    return _encrypt(peerUserId, CallSignal(type: CallSignalType.iceCandidate, callId: callId, candidate: candidate));
  }

  Future<String> encodeReject({required String peerUserId, required String callId}) {
    return _encrypt(peerUserId, CallSignal(type: CallSignalType.reject, callId: callId));
  }

  Future<String> encodeCancel({required String peerUserId, required String callId}) {
    return _encrypt(peerUserId, CallSignal(type: CallSignalType.cancel, callId: callId));
  }

  Future<String> encodeEnd({required String peerUserId, required String callId}) {
    return _encrypt(peerUserId, CallSignal(type: CallSignalType.end, callId: callId));
  }

  Future<String> encodeBusy({required String peerUserId, required String callId}) {
    return _encrypt(peerUserId, CallSignal(type: CallSignalType.busy, callId: callId));
  }

  Future<String> _encrypt(String peerUserId, CallSignal signal) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(signal.toJson())));
    return _crypto.encrypt(peerUserId, bytes);
  }

  /// Decrypts and parses a signaling message received from [senderUserId].
  /// Throws if `contentType` isn't a recognized call-signal type — check
  /// [isCallSignal] first, same as the `sender_key_distribution` check.
  Future<CallSignal> decode({required String senderUserId, required String contentType, required String ciphertext}) async {
    final type = CallSignalTypeContentType.fromContentType(contentType);
    if (type == null) {
      throw ArgumentError('not a call-signaling content_type: $contentType');
    }
    final plaintextBytes = await _crypto.decrypt(senderUserId, ciphertext);
    final json = jsonDecode(utf8.decode(plaintextBytes)) as Map<String, dynamic>;
    return CallSignal.fromJson(type, json);
  }
}
